import AppKit
import Foundation
import OSLog

/// TUN 的服务层：安装 / 授权 / 启动 / 停止 的唯一状态机。
///
/// 状态流转（§4.2）：
/// ```
/// off ──点击──▶ needsInstall ──说明卡确认──▶ awaitingAuthorization ──装好──▶ starting ──就绪──▶ on
///  ▲                │（取消）                       │（失败 / 超时）                │
///  └────────────────┴──────────────────────────────┴──────────────▶ failed(原因) ──点击──▶ 重试
/// on ──点击──▶ stopping ──确认内核已停──▶ off
/// ```
///
/// ## 不变量（本轮修的就是这几条）
/// 1. **任何终态都能再点**：忙碌判断只看 `starting / stopping`；安装流程用 `defer` 复位，
///    超时、取消、失败、崩溃路径都不会留下「磁贴永久 disabled」的闩锁
/// 2. **失败原因要分得开**：授权类（`authFailed`）与启动类（`startFailed`）是两种磁贴态，
///    banner 给的具体原因来自 helper 的中文回复（写配置失败 / spawn 失败 / 日志尾部）
/// 3. **不与别家 TUN 抢路由**：启动前检测默认路由与活跃 utun，发现其它客户端在接管流量就
///    明确拒绝并给可执行建议，而不是起一个必然打不通的内核
/// 4. **不改系统状态的东西一概不做**：不在没有授权的路径上跑 `osascript`，不 kill 别家进程
@MainActor
@Observable
final class TunService {

    // MARK: - 状态

    enum Phase: Equatable, Sendable {
        case off
        /// 需要授权 / 需要更新：磁贴「需要授权」，点击弹说明卡
        case needsInstall(TunInstallBlocker)
        /// 系统密码框已弹出，等用户操作
        case awaitingAuthorization
        /// 已送配置 / 已 spawn，等 `/version`
        case starting
        case on
        case stopping
        case failed(TunFailure)
    }

    enum TunInstallBlocker: Equatable, Sendable {
        /// 从没装过
        case notInstalled
        /// 装了但协议版本对不上（`HelperVersion` 变了）
        case outdated
        /// 组件已装好，但它的**运行目录**缺 geodata（安装时才会拷入）：
        /// 只能重装一次把用户目录里已下载的数据拷进去，helper 侧不新增接口
        case missingGeodata
    }

    enum TunFailure: Equatable, Sendable {
        case userCancelled
        case installFailed(String)
        case daemonNotRunning
        case versionMismatch
        /// 授权窗口超过预算（`authorizationTimeout`）
        case timeout
        /// 别的客户端已经在接管流量
        case conflict(String)
        /// 配置 / 启动 / 就绪失败（参数是中文原因，来自 helper 或本机校验）
        case startup(String)

        var userMessage: String {
            switch self {
            case .userCancelled:
                "已取消管理员授权，TUN 未开启"
            case .installFailed(let message):
                message
            case .daemonNotRunning:
                "组件已安装但未运行，请重启电脑后重试"
            case .versionMismatch:
                "管理员组件需要更新，需再次授权"
            case .timeout:
                "等待授权超时；若系统密码框仍在，请先取消它再重试"
            case .conflict(let message):
                message
            case .startup(let reason):
                "TUN 未开启：\(reason)"
            }
        }

        /// 授权类失败（磁贴走「授权失败」）；启动 / 冲突类走「开启失败」
        var isAuthorizationFailure: Bool {
            switch self {
            case .startup, .conflict: false
            case .userCancelled, .installFailed, .daemonNotRunning, .versionMismatch, .timeout: true
            }
        }
    }

    private(set) var phase: Phase = .off
    /// 失败文案（banner 用）；下一次操作时清空
    private(set) var failureMessage: String?
    /// 关闭后的复原校验提示（默认路由 / DNS 未回到基线）：TUN 确实关了，但网络可能还没恢复
    private(set) var restoreWarning: String?
    /// 说明卡：非 nil 时面板弹我们自己的授权说明（SwiftUI `.alert`，不用 `runModal`）
    ///
    /// 为什么不用 `NSAlert.runModal()`：菜单栏浮层是 `.popUpMenu` 级面板，模态会话一旦
    /// 不可见就会**吞掉所有点击**（真机现象：磁贴点了没反应、也没有窗口）。声明式 alert
    /// 不会有不可见模态会话。
    private(set) var installPrompt: TunInstallBlocker?

    private static let logger = Logger(subsystem: "com.clash.app", category: "tun")
    /// 等 `/version` 就绪的预算（与 `KernelService` 一致）
    private static let readinessTimeout: Duration = .seconds(8)
    /// 就绪轮询粒度：内核通常 300–800ms 起来，100ms 粒度会白等最多 100ms；50ms 更贴合
    private static let readinessPollInterval: Duration = .milliseconds(50)
    /// 「等待授权」的预算：超时后放弃等待（osascript 不会被我们打断，见 `awaitInstallOutcome`）
    static let authorizationTimeout: Duration = .seconds(180)

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let systemProxy: SystemProxyService
    @ObservationIgnored private let kernel: KernelService
    @ObservationIgnored private let client: HelperClient

    @ObservationIgnored private var enableTask: Task<Void, Never>?
    /// 安装流程是否在跑：**只在 `installThenEnable` 的 `defer` 里复位**，
    /// 超时 / 取消 / 抛错 / 该 Task 被丢弃都一定会走到
    @ObservationIgnored private var installFlowActive = false
    /// 开 TUN 前的网络基线：关闭时对比，判断路由 / DNS 是否复原
    @ObservationIgnored private var baseline: SystemNetworkSnapshot?
    /// helper 内核是否**可能**在跑（spawn 成功但还没被 `KernelService` 接管的那段时间也算）
    @ObservationIgnored private var hasHelperKernel = false
    /// `phase == .on` 时的 controller 端点：心跳 / 面板打开时用它复核内核是否还活着
    @ObservationIgnored private var livenessEndpoint: (port: Int, secret: String)?
    /// 30s 活性心跳：只在 `phase == .on` 期间存活，`disable()` / `fail()` / `deinit` 停掉
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    /// 心跳间隔：足够便宜（一次 XPC），又能把「面板显示已启用但内核已死」压到 30s 内
    private static let livenessInterval: Duration = .seconds(30)
    /// 正在热重载配置（切订阅 / 更新订阅）：期间磁贴禁用，也不允许 stop
    @ObservationIgnored private var isReloadingConfig = false

    init(
        settings: SettingsStore,
        systemProxy: SystemProxyService,
        kernel: KernelService,
        client: HelperClient = .shared
    ) {
        self.settings = settings
        self.systemProxy = systemProxy
        self.kernel = kernel
        self.client = client

        reapOrphanKernelIfNeeded()
    }

    deinit {
        heartbeatTask?.cancel()
    }

    // MARK: - 派生状态

    var isOn: Bool { phase == .on }

    /// helper 侧可能仍有 root 内核在跑（含「已 spawn 但尚未接管」的窗口）
    var isHelperKernelRunning: Bool { hasHelperKernel || kernel.isExternal }

    /// 只有真正的过渡态才禁用磁贴。
    ///
    /// `needsInstall / awaitingAuthorization / failed / off` 一律可点：用户点下去必须
    /// 有反馈（弹说明卡 / 提示「密码框已弹出」/ 直接重试），不能变成死的。
    var isBusy: Bool {
        if isReloadingConfig { return true }
        switch phase {
        case .starting, .stopping: return true
        case .off, .needsInstall, .awaitingAuthorization, .on, .failed: return false
        }
    }

    var isInstalling: Bool { installFlowActive }

    /// 磁贴状态（§4.2）：五态 + 过渡 + 启动失败
    var tileState: TunState {
        switch phase {
        case .off: .off
        case .needsInstall: .requiresAuth
        case .awaitingAuthorization: .waitingAuth
        case .starting: .starting
        case .on: .on
        case .stopping: .stopping
        case .failed(let failure): failure.isAuthorizationFailure ? .authFailed : .startFailed
        }
    }

    /// banner 文案：失败优先，其次复原告警
    var bannerMessage: String? { failureMessage ?? restoreWarning }

    // MARK: - 入口

    /// 磁贴点击：任何「不是过渡态」的状态都要有明确反馈。
    func toggle() {
        guard !isReloadingConfig else { return }
        switch phase {
        case .on:
            Task { [weak self] in await self?.disable() }
        case .starting, .stopping:
            return
        case .awaitingAuthorization:
            // 授权窗口在 osascript 进程里：我们没法把它拉到前台，只能提示别重复点
            failureMessage = "系统密码框已弹出，请完成或取消后再点 TUN"
        case .off, .needsInstall, .failed:
            requestEnable()
        }
    }

    /// 编程入口（自检 / 未来的自动重连）：跳过说明卡，直接走启动
    func enable() async {
        guard !isBusy, phase != .on, !installFlowActive else { return }
        await enableInternal(retryingAfterInstall: false)
    }

    private func requestEnable() {
        guard !isBusy else { return }
        // 系统代理正在切换：此刻 `isEnabled` 仍是 false，放行就会漏掉「先关代理」，
        // 最终变成两个接管同开。服务层以 `isTransitioning` 为准，不依赖 UI 派生的 busy。
        guard !systemProxy.isTransitioning else {
            failureMessage = "系统代理正在切换，请稍候"
            return
        }
        // 内核正在 start/stop：TUN 此刻抢同一个 mixed-port 只会得到「端口被占用」，
        // 而 kernel.stop() 会因过渡中直接返回。等内核稳定后用户再点一次。
        guard !kernel.isTransitioning else {
            failureMessage = "内核正在启动，请稍候"
            return
        }
        guard !installFlowActive else {
            failureMessage = "正在安装组件，请稍候"
            return
        }
        failureMessage = nil
        restoreWarning = nil
        installPrompt = nil

        // 已装（且 launchd 里 job 在）→ 直接走启动；版本 / 运行时是否齐全在 enable 里查
        if HelperInstaller.isInstalled {
            startEnable()
            return
        }

        // 未装：先进「需要授权」，再弹我们自己的说明卡；确认之前绝不碰 osascript
        phase = .needsInstall(.notInstalled)
        installPrompt = .notInstalled
    }

    // MARK: - 说明卡（由面板以 SwiftUI alert 呈现）

    func confirmInstallPrompt() {
        guard installPrompt != nil else { return }
        installPrompt = nil
        beginInstall()
    }

    func cancelInstallPrompt() {
        guard let blocker = installPrompt else { return }
        installPrompt = nil
        // 取消不等于「没这个需求」：留在「需要授权」态，磁贴还能再点重试。
        // 只有 `.notInstalled` 走回原来的 off（此时连组件都没有，语义就是「没开」）。
        switch blocker {
        case .notInstalled:
            phase = .off
            failureMessage = TunFailure.userCancelled.userMessage
        case .outdated:
            phase = .needsInstall(blocker)
            failureMessage = "管理员组件需要更新：点 TUN 可再次授权安装"
        case .missingGeodata:
            phase = .needsInstall(blocker)
            failureMessage = "组件运行目录仍缺地理数据：点 TUN 可再次授权，重新安装会把已下载的数据拷进去"
        }
    }

    /// 用户按 Esc / 点外部关闭：只收起说明卡，保持「需要授权」，不改变其它状态
    func dismissInstallPrompt() {
        installPrompt = nil
    }

    // MARK: - 安装（本轮允许真跑，但只在用户确认后）

    private func beginInstall() {
        guard !installFlowActive else { return }
        installFlowActive = true
        Task { [weak self] in
            await self?.installThenEnable()
        }
    }

    /// 安装 → 成功后直接启动。
    ///
    /// `defer` 是硬性要求：**任何**退出路径（成功 / 取消 / 失败 / 超时 / 抛错）都必须
    /// 把 `installFlowActive` 复位，否则磁贴会永久 disabled —— 这正是真机卡死的原因。
    private func installThenEnable() async {
        defer { installFlowActive = false }

        // 包内不再带内核（ADR-0012）：安装脚本要从用户目录拷入，所以先把内核（与订阅需要的
        // geodata）准备好；失败就不弹密码框，直接给明确原因
        do {
            try await kernel.ensureKernelAvailable()
            try await kernel.ensureGeodataIfNeeded()
        } catch {
            fail(.startup(Self.describe(error)))
            return
        }

        phase = .awaitingAuthorization
        let outcome = await awaitInstallOutcome()

        switch outcome {
        case .installed:
            guard HelperInstaller.isInstalled else {
                fail(.daemonNotRunning)
                return
            }
            await enableInternal(retryingAfterInstall: true)
        case .cancelled:
            phase = .off
            failureMessage = TunFailure.userCancelled.userMessage
        case .failed(let error):
            fail(error == .daemonNotRunning ? .daemonNotRunning : .installFailed(error.userMessage))
        case .timedOut:
            fail(.timeout)
        }
    }

    private enum InstallOutcome: Sendable {
        case installed
        case cancelled
        case failed(HelperInstallError)
        case timedOut
    }

    /// 跑安装，并在 `authorizationTimeout` 后放弃等待。
    ///
    /// 为什么不能「取消安装任务」：`osascript` 的密码框在独立进程里，取消 Swift Task
    /// 不会关掉它。所以超时只表示「我们不再等」，密码框仍由用户自己取消；
    /// 若之后安装真的完成，`isInstalled` 会变成 true，下次点击直接走启动、不会重复弹框。
    private func awaitInstallOutcome() async -> InstallOutcome {
        let gate = InstallOutcomeGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<InstallOutcome, Never>) in
            Task {
                let outcome: InstallOutcome
                do {
                    try await HelperInstaller.install()
                    outcome = .installed
                } catch let error as HelperInstallError {
                    outcome = error == .userCancelled ? .cancelled : .failed(error)
                } catch {
                    outcome = .failed(.installFailed(detail: error.localizedDescription))
                }

                guard gate.claim() else {
                    // 超时之后迟到的结果：只记日志，不自动开启（用户可能已经放弃）
                    Self.logger.notice("安装结果迟到（已超时）：\(String(describing: outcome), privacy: .public)")
                    return
                }
                continuation.resume(returning: outcome)
            }

            Task {
                try? await Task.sleep(for: Self.authorizationTimeout)
                guard gate.claim() else { return }
                continuation.resume(returning: .timedOut)
            }
        }
    }

    // MARK: - 开启

    private func startEnable() {
        enableTask?.cancel()
        enableTask = Task { [weak self] in
            defer { self?.enableTask = nil }
            await self?.enableInternal(retryingAfterInstall: false)
        }
    }

    /// 开启主流程：版本/运行时 → 冲突检测 → 互斥关代理 → 本地内核让位 → 生成正文 →
    /// 送配置 → 启动 → 就绪 → 接管端点
    private func enableInternal(retryingAfterInstall: Bool) async {
        // 系统代理仍在切换（例如刚点完「连接」）：先关代理这一步必须成立，
        // 否则内核若已接管 7890，`disable()` 也会失败 → 两个接管同开。
        guard !systemProxy.isTransitioning else {
            fail(.startup("系统代理正在切换，请稍候"))
            return
        }
        failureMessage = nil
        restoreWarning = nil
        phase = .starting
        let total = LatencyTrace.shared.begin()
        defer { LatencyTrace.shared.record("total", from: total) }

        // 0. 内核可能已被「完全清理」删掉：启用前同样确保存在（ADR-0012）
        do {
            try await kernel.ensureKernelAvailable()
            try await kernel.ensureGeodataIfNeeded()
        } catch {
            fail(.startup(Self.describe(error)))
            return
        }

        // 1. 协议版本 + 运行时自检（缺内核 / 目录不完整时直接给准确原因，不去 spawn 再失败）
        let snapshot: HelperRuntimeSnapshot
        do {
            snapshot = try await client.checkVersion()
        } catch HelperClientError.versionMismatch {
            if retryingAfterInstall {
                fail(.versionMismatch)
                return
            }
            phase = .needsInstall(.outdated)
            failureMessage = "管理员组件需要更新，需再次授权"
            installPrompt = .outdated
            return
        } catch {
            if retryingAfterInstall {
                fail(.daemonNotRunning)
                return
            }
            phase = .needsInstall(.notInstalled)
            installPrompt = .notInstalled
            return
        }

        if snapshot.kernelBinaryPresent == false || snapshot.supportDirectoryPresent == false {
            var missing: [String] = []
            if snapshot.kernelBinaryPresent == false { missing.append("内核文件") }
            if snapshot.supportDirectoryPresent == false { missing.append("运行目录") }
            fail(.startup("管理员组件不完整（缺少\(missing.joined(separator: "、"))），请在设置里重新安装"))
            return
        }

        // 2. helper 侧预检（AUDIT A6）：上一次 `stopKernel` 失败 / App 崩溃后，helper 可能
        //    还持有一个旧内核，而本进程的 `phase` 是 off / failed ——「App 不知道」。
        //    `KernelSupervisor.startLocked()` 见到运行中的进程会直接复用、**不重载
        //    runtime.yaml**，于是新 controller 端口永远等不到 `/version`（8s 超时），
        //    而且这 8s 之后还会把本来能用的旧内核杀掉。
        //    必须放在冲突检测**之前**：旧内核的 utun 会被误判成「别家 TUN」，先停掉才能
        //    看到真实的网络状态；也顺便让 mixed-port 提前释放。
        if let existingPID = (try? await client.kernelState()) ?? nil, !existingPID.isEmpty {
            Self.logger.notice("启动前发现 helper 已有内核 pid=\(existingPID, privacy: .public)，先停掉")
            try? await client.stopKernel()
            let remainingPID = (try? await client.kernelState()) ?? nil
            if let remainingPID, !remainingPID.isEmpty {
                fail(.startup("上一个 TUN 内核未能停止（pid=\(remainingPID)），请重试"))
                return
            }
            hasHelperKernel = false
            guard await waitForPortRelease(settings.mixedPort) else {
                fail(.startup("端口 \(settings.mixedPort) 已被占用，请先释放"))
                return
            }
            Self.logger.notice("上一个 TUN 内核已停止 pid=\(existingPID, privacy: .public)")
        }

        // 3. 别家 TUN / VPN 已在接管流量：不抢路由，直接给可执行建议。
        //    基线（关闭 TUN 后判断路由 / DNS 是否复原）与冲突检测并发：两者互不依赖，
        //    且都必须发生在 spawn 之前（抓的是「TUN 之前的网络状态」）。
        let baselineTask = Task { await SystemNetworkProbe.capture() }
        let conflictStart = LatencyTrace.shared.begin()
        let conflict = await TunConflictDetector.detect(baseline: { await baselineTask.value })
        LatencyTrace.shared.record("conflict", from: conflictStart)
        if let conflict {
            Self.logger.error("TUN 冲突：\(conflict.summary, privacy: .public)")
            fail(.conflict(conflict.userMessage))
            return
        }

        // 3.5 GeoIP / GeoSite 数据库：缺了内核会去 jsdelivr 下载（国内 90s 超时 → 表现为
        //    「8 秒未就绪」），先拦下。两侧分开处理：
        //    - 用户目录缺 → `ensureGeodataIfNeeded` 已跑过仍缺，是下载失败，给网络原因
        //    - helper 运行目录缺 → 只有「重新安装组件」能拷入，走说明卡，不是死路
        let profileURL = ProfileLocator.locate()
        let geodataGap = await TunGeodataProbe.gap(profileURL: profileURL)
        if !geodataGap.userDirectory.isEmpty {
            fail(.startup("地理数据下载不完整（缺少 \(geodataGap.userDirectory.joined(separator: "、"))），"
                + "请检查网络后重试"))
            return
        }
        if !geodataGap.helperDirectory.isEmpty {
            let missing = geodataGap.helperDirectory.joined(separator: "、")
            guard !retryingAfterInstall else {
                // 重装过了还缺：说明用户目录里没有可拷入的文件（`geosite.dat` 下载失败只告警）
                fail(.startup("重新安装后组件运行目录仍缺 \(missing)，"
                    + "请检查网络让 App 下载好地理数据后再重装组件"))
                return
            }
            phase = .needsInstall(.missingGeodata)
            installPrompt = .missingGeodata
            failureMessage = "组件运行目录缺少 \(missing)：重新安装会把已下载的地理数据拷进去"
                + "（需要管理员密码），否则内核会去在线下载并超时"
            return
        }

        // 4. 互斥：系统代理与 TUN 不能同时接管流量
        if systemProxy.isEnabled {
            let closeStart = LatencyTrace.shared.begin()
            do {
                try await systemProxy.disable()
            } catch {
                fail(.startup("无法关闭系统代理，请先手动关闭"))
                return
            }
            LatencyTrace.shared.record("closeProxy", from: closeStart)
        }

        // 5. 本地内核让位：两者用同一个 mixed-port
        if kernel.phase == .running || kernel.phase == .starting {
            let stopStart = LatencyTrace.shared.begin()
            await kernel.stop()
            LatencyTrace.shared.record("stopLocalKernel", from: stopStart)
        }

        // 6. 生成本轮端点与正文（端口 / secret 由 App 决定，随正文一起送 helper）
        let ports: [Int]
        do {
            ports = try PortAllocator.allocateDistinct(2)
        } catch {
            fail(.startup("无法分配本地端口"))
            return
        }

        let mixedPort = settings.mixedPort
        guard await waitForPortRelease(mixedPort) else {
            fail(.startup("端口 \(mixedPort) 已被占用，请先释放"))
            return
        }

        let secret = RuntimeConfigBuilder.makeSecret()
        let injected = RuntimeConfigBuilder.Injected(
            mixedPort: mixedPort,
            allowLAN: settings.allowLAN,
            controllerPort: ports[0],
            dnsPort: ports[1],
            secret: secret,
            logLevel: settings.logLevel.cliValue,
            mode: settings.mode,
            tunEnabled: true,
            tunStack: .gvisor
        )

        let yaml: String
        do {
            let buildStart = LatencyTrace.shared.begin()
            yaml = try await RuntimeConfigBuilder.yaml(from: profileURL, injected: injected)
            LatencyTrace.shared.record("buildYaml", from: buildStart)
        } catch {
            fail(.startup((error as? KernelError)?.userMessage ?? "生成运行配置失败"))
            return
        }

        // 7. 基线：第 3 步就已经并发开始抓（关闭时用它判断路由 / DNS 是否复原）
        baseline = await baselineTask.value

        // AUDIT: 真机诊断——送进去的端点是否与实际监听一致
        Self.logger.notice("AUDIT 准备 spawn 配置=\(yaml.utf8.count)bytes controller=127.0.0.1:\(ports[0]) dns=:\(ports[1]) mixed=\(mixedPort) secretLen=\(secret.count)")

        // 8. 送配置 → 启动 root 内核（两步 XPC；失败时停一次防半开）
        let runner = HelperKernelRunner(client: client)
        do {
            _ = try await runner.start(configData: Data(yaml.utf8))
            hasHelperKernel = true
        } catch {
            guard await stopHelperKernel(runner) else { return }
            fail(.startup(Self.describe(error)))
            return
        }

        // 9. 等 `/version`：spawn 成功不等于可用（端口冲突 / 配置错误都在这一步暴露）
        let version: String
        do {
            let readyStart = LatencyTrace.shared.begin()
            version = try await waitUntilReady(port: ports[0], secret: secret)
            LatencyTrace.shared.record("ready", from: readyStart)
        } catch {
            Self.logger.notice("AUDIT 就绪失败，准备 stop runner")
            // 停不掉就不能继续往下走：先确认退出，再决定 banner 说什么
            guard await stopHelperKernel(runner) else { return }
            Self.logger.notice("AUDIT stop runner 已确认退出")
            // root 的 kernel.log 是 0600，用户读不到：只有 helper 目录**确实**缺 geodata 时
            // 才把「在等在线下载」写进 banner，其余情况给通用排查方向，别默认甩锅 geodata。
            let hint = await Self.readinessTimeoutHint(profileURL: profileURL, mixedPort: mixedPort)
            fail(.startup("内核启动后 \(Int(Self.readinessTimeout.components.seconds)) 秒内未就绪" + hint))
            return
        }

        // 10. 接管 API 端点：面板的策略组 / 流量 / 连接 / 日志都从这里取数
        kernel.adoptExternalKernel(
            port: ports[0],
            secret: secret,
            version: version,
            mixedPort: mixedPort,
            dnsPort: ports[1],
            logLevel: settings.logLevel.cliValue,
            allowLAN: settings.allowLAN,
            hasProfile: profileURL != nil
        )

        phase = .on
        failureMessage = nil
        livenessEndpoint = (ports[0], secret)
        startLivenessHeartbeat()
        Self.logger.notice("TUN 已开启 controller=127.0.0.1:\(ports[0]) version=\(version, privacy: .public)")
    }

    // MARK: - 热重载（切订阅 / 更新订阅）

    /// TUN 内核热重载：新正文经 helper 落盘 → 对**当前已接管的 controller** 发
    /// `PUT /configs?force=true`。root 内核 pid、controller 端口、secret、DNS 端口、utun 都不变。
    ///
    /// 失败抛错，由调用方回退原来的 disable + enable；这里不改相位，成功后面板需要主动刷新
    /// `/proxies`（相位一直是 `.on`，不会触发 `onPhaseChange`）。
    func reloadProfile() async throws {
        guard isOn, !isReloadingConfig,
              let controllerPort = kernel.port, let secret = kernel.secret,
              let mixedPort = kernel.activeMixedPort, let dnsPort = kernel.activeDNSPort else {
            throw HotReloadError.notRunning
        }
        guard let profileURL = ProfileLocator.locate() else { throw HotReloadError.missingEndpoint }
        guard let beforePID = (try? await client.kernelState()) ?? nil else {
            throw HotReloadError.notRunning
        }

        isReloadingConfig = true
        defer { isReloadingConfig = false }
        let began = ContinuousClock.now
        let beforeTunnels = await Self.tunnelInterfaces()

        let injected = RuntimeConfigBuilder.Injected(
            mixedPort: mixedPort,
            allowLAN: settings.allowLAN,
            controllerPort: controllerPort,
            dnsPort: dnsPort,
            secret: secret,
            logLevel: settings.logLevel.cliValue,
            mode: settings.mode,
            tunEnabled: true,
            tunStack: .gvisor
        )
        let generated = try await RuntimeConfigBuilder.generate(from: profileURL, injected: injected)
        try Task.checkCancellation()

        // 先落盘再重载：即使 PUT 失败，回退的 disable→enable 也会用这份新正文
        try await client.applyRuntimeConfig(Data(generated.yaml.utf8))
        try Task.checkCancellation()

        let api = ClashAPIClient(port: controllerPort, secret: secret, timeout: 5)
        let expectation = ReloadExpectation(
            groupNames: generated.groupNames,
            proxyNames: generated.proxyNames
        )
        do {
            try await api.reloadConfig(path: HelperLayout.runtimeConfigPath)
        } catch {
            try Task.checkCancellation()
            Self.logger.notice(
                "TUN path 方式热重载失败，改用 payload：\(String(describing: error), privacy: .public)"
            )
            try await api.reloadConfig(payload: generated.yaml)
        }

        try await ReloadVerifier.wait(client: api, expectation: expectation)

        // 进程 / 隧道断言：热重载必须是「就地换配置」，不许换内核、不许重建 utun
        let afterPID = (try? await client.kernelState()) ?? nil
        guard let afterPID, afterPID == beforePID else {
            throw HotReloadError.kernelRestarted(before: beforePID, after: afterPID)
        }
        let afterTunnels = await Self.tunnelInterfaces()
        guard afterTunnels == beforeTunnels else {
            throw HotReloadError.tunnelChanged
        }

        let elapsed = Self.milliseconds(from: began)
        let pid = afterPID
        let tunnelCount = afterTunnels.count
        let groupCount = generated.groupNames.count
        let proxyCount = generated.proxyNames.count
        Self.logger.notice(
            "TUN 配置热重载完成 用时=\(elapsed)ms pid=\(pid, privacy: .public) utun=\(tunnelCount) groups=\(groupCount) proxies=\(proxyCount)"
        )
    }

    /// `ifconfig -a` 里的 utun 接口名集合（热重载前后必须一致）
    private static func tunnelInterfaces() async -> Set<String> {
        guard let output = await SystemNetworkProbe.runCommand("/sbin/ifconfig", ["-a"]) else {
            return []
        }
        var names: Set<String> = []
        for line in output.split(separator: "\n") {
            let text = String(line)
            // 只有一个接口的头部行不带缩进；正文（地址 / 标志）都是缩进的
            guard !text.hasPrefix("\t"), !text.hasPrefix(" ") else { continue }
            let name = text.split(separator: ":").first.map(String.init) ?? ""
            if name.hasPrefix("utun") { names.insert(name) }
        }
        return names
    }

    private static func milliseconds(from start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// 等 mixed-port 真正释放：刚停掉本地内核时，进程退出 / TIME_WAIT 会让第一次探测失败。
    /// 先立即探一次（端口本来就空=零等待），再 50ms 粒度轮询，总预算仍是 ~1.8s。
    private func waitForPortRelease(_ port: Int) async -> Bool {
        if PortAllocator.isAvailable(port: port) { return true }
        for _ in 0..<35 {
            try? await Task.sleep(for: .milliseconds(50))
            if PortAllocator.isAvailable(port: port) { return true }
        }
        return PortAllocator.isAvailable(port: port)
    }

    /// 轮询 `/version`；成功即就绪
    private func waitUntilReady(port: Int, secret: String) async throws -> String {
        let probe = ClashAPIClient(port: port, secret: secret, timeout: 1)
        let deadline = ContinuousClock.now + Self.readinessTimeout
        // AUDIT: 真机诊断——每次轮询的耗时与错误（区分「慢」「死」「端口/secret 不对」）
        let began = ContinuousClock.now
        var attempt = 0
        Self.logger.notice("AUDIT waitUntilReady 开始 port=\(port) secretLen=\(secret.count) timeout=\(Int(Self.readinessTimeout.components.seconds))s")
        while ContinuousClock.now < deadline {
            attempt += 1
            do {
                let response = try await probe.version(timeout: 1)
                let elapsed = Self.ms(from: began)
                Self.logger.notice("AUDIT waitUntilReady 就绪 attempt=\(attempt) 耗时=\(elapsed)ms version=\(response.version, privacy: .public)")
                return response.version
            } catch {
                let elapsed = Self.ms(from: began)
                // 只记前 5 次与之后每 10 次：8s 预算下最多 80 次，全记会淹没日志
                if attempt <= 5 || attempt % 10 == 0 {
                    Self.logger.notice("AUDIT waitUntilReady 未就绪 attempt=\(attempt) 耗时=\(elapsed)ms port=\(port) err=\(String(describing: error), privacy: .public)")
                }
            }
            try? await Task.sleep(for: Self.readinessPollInterval)
        }
        Self.logger.error("AUDIT waitUntilReady 超时 attempt=\(attempt) port=\(port) 预算=\(Int(Self.readinessTimeout.components.seconds))s")
        throw TunError.notReady
    }

    private static func ms(from start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - 活性校验（AUDIT A3）

    /// 面板打开时校验一次：避免「打开面板看到假的已启用」（内核可能被 kill / 被别的实例回收）。
    /// 失败后状态机自己落到 `.failed` + banner，无需调用方处理返回值。
    func verifyLiveness() async {
        guard phase == .on, let endpoint = livenessEndpoint else { return }
        guard await isKernelAlive(endpoint) else {
            handleKernelGone()
            return
        }
    }

    private func startLivenessHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.livenessInterval)
                guard !Task.isCancelled, let self else { return }
                await self.verifyLiveness()
            }
        }
    }

    private func stopLivenessHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        livenessEndpoint = nil
    }

    /// 内核是否还活着：先问 helper（拿得到 pid 即活着），拿不到再用已接管的 API 复核一次。
    /// 只有**两者都失败**才判定退出——XPC / 单次 HTTP 抖动不能把用户踢回失败态。
    private func isKernelAlive(_ endpoint: (port: Int, secret: String)) async -> Bool {
        if let pid = (try? await client.kernelState()) ?? nil, !pid.isEmpty { return true }
        let probe = ClashAPIClient(port: endpoint.port, secret: endpoint.secret, timeout: 2)
        do {
            _ = try await probe.version(timeout: 2)
            return true
        } catch {
            Self.logger.notice("活性校验：helper 无 pid 且 API 不可达（\(String(describing: error), privacy: .public)）")
            return false
        }
    }

    /// 心跳 / 面板校验发现内核已退出：释放端点并落到失败态，再由 `fail()` 回落本地内核。
    ///
    /// 不用 `fail()` 直接收尾：那里刻意保留 `hasHelperKernel` / 端点（失败可能发生在内核
    /// 仍在跑时）。这里两路校验都失败 = 内核确定不在，必须释放，否则面板一直拿死端点取数。
    private func handleKernelGone() {
        guard phase == .on else { return }
        stopLivenessHeartbeat()
        hasHelperKernel = false
        kernel.releaseExternalKernel()
        let reason = "TUN 内核已退出（可能被其它进程关闭），请重新开启"
        Self.logger.error("\(reason, privacy: .public)：helper 无 pid 且 API 不可达")
        fail(.startup(reason))
    }

    // MARK: - 关闭

    /// 关闭：`stopKernel`（XPC 等确认）→ 释放端点 → 校验默认路由 / DNS → off
    ///
    /// - Parameter restartLocalKernel: 关闭后是否把本地（用户态）内核拉回来。
    ///   默认 `true`（用户点 TUN 关掉后仍要有节点可选）；「接着要开系统代理」的路径传
    ///   `false`——那边需要自己按 `running` 等待，不能被这里的自动重启抢跑。
    func disable(restartLocalKernel: Bool = true) async {
        // 热重载正在进行：stop 会把 PUT /configs 的会话截断，先让重载收尾
        guard !isReloadingConfig else { return }
        guard isOn || isHelperKernelRunning else { return }

        let total = LatencyTrace.shared.begin()
        defer { LatencyTrace.shared.record("total", from: total) }

        stopLivenessHeartbeat()
        phase = .stopping
        // 只有「确认退出」才允许继续往下走（含置 off / 释放端点）
        let stopStart = LatencyTrace.shared.begin()
        guard await stopHelperKernel(HelperKernelRunner(client: client)) else { return }
        LatencyTrace.shared.record("stopKernel", from: stopStart)

        if let baseline {
            let verifyStart = LatencyTrace.shared.begin()
            let differences = await SystemNetworkProbe.capture().differences(from: baseline)
            LatencyTrace.shared.record("verify", from: verifyStart)
            if !differences.isEmpty {
                restoreWarning = "已关闭 TUN，但\(differences.joined(separator: "；"))。若仍无法上网，请重启网络或重启电脑"
                Self.logger.error("TUN 关闭后网络未复原：\(differences.joined(separator: "；"), privacy: .public)")
            }
        }
        self.baseline = nil

        phase = .off
        failureMessage = nil
        Self.logger.notice("TUN 已关闭")

        if restartLocalKernel {
            await restartLocalKernelIfNeeded()
        }
    }

    #if DEBUG
    /// 自检夹具（`CLASH_AUDIT_B1`）：模拟「helper 仍有内核、但 App 已经失忆」——
    /// 不调用 `stopKernel`，只把本地状态清回 off，用来验证启动前预检（AUDIT A6）。
    /// 真实场景是上一次 stopKernel 失败后用户直接重试。
    func simulateForgottenHelperKernelForAudit() {
        stopLivenessHeartbeat()
        hasHelperKernel = false
        kernel.releaseExternalKernel()
        phase = .off
        failureMessage = nil
    }
    #endif

    // MARK: - 失败与回落

    private func fail(_ failure: TunFailure) {
        stopLivenessHeartbeat()
        phase = .failed(failure)
        failureMessage = failure.userMessage
        installPrompt = nil
        // 刻意不动 `hasHelperKernel` / 不 `releaseExternalKernel()`：
        // 「内核已退出」只能由 `stopHelperKernel` 确认后改写。这里的失败可能发生在
        // root 内核仍在运行的场景（停止失败 / 就绪超时），无条件置 off 会谎报。
        Self.logger.error("TUN 失败：\(failure.userMessage, privacy: .public)")

        // 起不来就回落系统代理模式：本地内核拉回来，用户还能继续用面板
        Task { [weak self] in
            await self?.restartLocalKernelIfNeeded()
        }
    }

    /// 停 helper 内核并要求 helper **确认退出**；返回是否确认已退出。
    ///
    /// 停不掉时以 helper 的真实状态（`kernelState()`）为准：还活着就保留 `.failed` +
    /// 「内核可能仍在运行」，绝不显示「未启用」。
    @discardableResult
    private func stopHelperKernel(_ runner: HelperKernelRunner) async -> Bool {
        do {
            try await runner.stopThrowing()
            hasHelperKernel = false
            kernel.releaseExternalKernel()
            return true
        } catch {
            let stillRunning = (try? await client.kernelState()) ?? nil
            if let stillRunning {
                // 内核还在跑：TUN 没关掉，流量仍被接管。保留端点，让面板说实话。
                hasHelperKernel = true
                let reason = "内核可能仍在运行（pid=\(stillRunning)）：TUN 未真正关闭，请再点一次 TUN 或重启 App"
                phase = .failed(.startup(reason))
                failureMessage = reason
                Self.logger.error("无法停止 TUN 内核 pid=\(stillRunning, privacy: .public)：\(error.localizedDescription, privacy: .public)")
                return false
            }
            // helper 说没有内核：视为已退出
            hasHelperKernel = false
            kernel.releaseExternalKernel()
            Self.logger.notice("stopKernel 报错但 helper 侧已无内核，按已关闭处理：\(error.localizedDescription, privacy: .public)")
            return true
        }
    }

    private func restartLocalKernelIfNeeded() async {
        guard !kernel.isExternal, kernel.phase != .running, !kernel.isTransitioning else { return }
        // 用「盘上现在有没有配置」判断，而不是 `kernel.hasProfile`：刚删掉最后一条订阅时
        // 后者还是 true，会把内核用空配置拉起来
        guard ProfileLocator.locate() != nil else { return }
        // 刚停掉的 TUN 内核还在收尾时，7890 上可能残留它的连接（ESTABLISHED / FIN_WAIT），
        // 直接抢会得到 portInUse。先等端口真正可绑，再拉本地内核。
        _ = await waitForPortRelease(settings.mixedPort)
        await kernel.start()
    }

    /// 截图 / 自检夹具（`CLASH_PREVIEW_PAGE`、`CLASH_TUN_SMOKE`、`*_HARNESS` 等）：没有用户会话
    private static var isAutomationFixture: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["CLASH_PREVIEW_PAGE"] != nil { return true }
        if environment["CLASH_TUN_SMOKE"] != nil { return true }
        if environment["CLASH_TUN_CONFIG_HARNESS"] != nil { return true }
        if environment.keys.contains(where: { $0.hasPrefix("CLASH_AUDIT_") }) { return true }
        return environment.contains { key, value in key.hasSuffix("_HARNESS") && !value.isEmpty }
    }

    /// 同 bundle 的另一个实例是否在跑（排除自己）：它在用 helper 内核时不能被我们回收
    private static var isAnotherInstanceRunning: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != me }
    }

    /// 启动时清理上一次会话遗留的 root 内核（`kill -9` / 崩溃时退出清理没机会跑）。
    ///
    /// helper 是 launchd 常驻，内核是它的子进程：App 没了内核照样在接管流量，而面板显示
    /// 「已关闭」——用户会以为没开 TUN 却上不了网。这里像 `OrphanKernelReaper` 一样先清掉。
    ///
    /// **两条前置**（AUDIT A4）：截图 / 自检夹具不承载用户会话；本 bundle 还有第二个实例时
    /// 那个实例可能正用着这个 TUN 内核，抢过来就是「预览把用户的 TUN 杀了」。
    private func reapOrphanKernelIfNeeded() {
        Task { [weak self] in
            guard let self else { return }
            guard !Self.isAutomationFixture else { return }
            guard !Self.isAnotherInstanceRunning else {
                Self.logger.notice("检测到同 bundle 的另一个实例，跳过遗留内核回收")
                return
            }
            // 没装组件就不去连：省一次必然失败的 XPC，也避免启动日志里出现无害的 error
            guard HelperInstaller.isInstalled else { return }
            let running = (try? await self.client.kernelState()) ?? nil
            guard let running, !self.isOn, !self.kernel.isExternal else { return }
            Self.logger.notice("发现遗留的 TUN 内核 pid=\(running, privacy: .public)，先停掉")
            try? await self.client.stopKernel()
        }
    }

    /// 8 秒超时的真实原因提示：**只有 helper 运行目录确实缺 geodata** 才提地理数据
    /// （内核在等在线下载）。其余情况给通用排查方向，避免把无关超时误导成 geodata 缺失。
    private static func readinessTimeoutHint(profileURL: URL?, mixedPort: Int) async -> String {
        let gap = await TunGeodataProbe.gap(profileURL: profileURL)
        guard !gap.helperDirectory.isEmpty else {
            return "（常见原因：\(mixedPort) 端口交接未完成 / 配置错误，详见 \(HelperLayout.kernelLogPath)）"
        }
        return "（缺少 \(gap.helperDirectory.joined(separator: "、"))，内核正在尝试在线下载地理数据）"
    }

    private static func describe(_ error: Error) -> String {
        if let helper = error as? HelperClientError { return helper.userMessage }
        if let kernel = error as? KernelError { return kernel.userMessage }
        if let provision = error as? KernelProvisionError { return provision.userMessage }
        return error.localizedDescription
    }
}

/// 让「安装结果」与「超时」只有一个赢家（`CheckedContinuation` 只允许 resume 一次）
private final class InstallOutcomeGate: @unchecked Sendable {

    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private enum TunError: Error, Equatable {
    case notReady
}
