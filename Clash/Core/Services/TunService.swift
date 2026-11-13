import Foundation
import OSLog

/// TUN 的服务层：安装 / 授权 / 启动 / 停止 的唯一状态机。
///
/// 状态流转（§4.2）：
/// ```
/// off ──点击──▶ needsInstall ──确认──▶ awaitingAuthorization ──安装成功──▶ starting ──就绪──▶ on
///  ▲                │（取消）                    │（失败 / 超时）                    │
///  └────────────────┴───────────────────────────┴──────────────▶ failed(原因)
/// on ──点击──▶ stopping ──确认内核已停──▶ off
/// ```
///
/// 边界：
/// - **不执行任何 root 写操作**：安装走 `HelperInstaller`（osascript 一次授权），
///   运行配置 / 内核启停走 XPC；本类只做编排与校验
/// - **与系统代理互斥**：开 TUN 前先 `systemProxy.disable()`；开代理前由面板先关 TUN
/// - **失败必回落**：helper 起不来就把本地内核拉回来，并在 banner 给可执行建议
/// - **退出不留尾巴**：App 退出时由 `AppTerminationGuard` 同步 `stopKernel`
///   （helper 是 launchd 常驻，不随 App 退出）
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
    }

    enum TunFailure: Equatable, Sendable {
        case userCancelled
        case installFailed(String)
        case daemonNotRunning
        case versionMismatch
        /// 授权窗口超过预算（`authorizationTimeout`）
        case timeout
        /// 配置 / 启动 / 就绪失败（参数是中文原因）
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
                "等待授权超时，请重试"
            case .startup(let reason):
                "TUN 未开启：\(reason)"
            }
        }

        /// 授权类失败（磁贴走「授权失败」态）；启动失败另算
        var isAuthorizationFailure: Bool {
            switch self {
            case .startup: false
            case .userCancelled, .installFailed, .daemonNotRunning, .versionMismatch, .timeout: true
            }
        }
    }

    private(set) var phase: Phase = .off
    /// 失败文案（banner 用）；成功 / 关闭成功后清空
    private(set) var failureMessage: String?
    /// 关闭后的复原校验提示（默认路由 / DNS 未回到基线）：TUN 确实关了，但网络可能还没恢复
    private(set) var restoreWarning: String?

    private static let logger = Logger(subsystem: "com.clash.app", category: "tun")
    /// 等 `/version` 就绪的预算（与 `KernelService` 一致）
    private static let readinessTimeout: Duration = .seconds(8)
    private static let readinessPollInterval: Duration = .milliseconds(100)
    /// 「等待授权」的上限：超时不再等（osascript 进程本身不会被打断，见 `awaitInstallOutcome`）
    private static let authorizationTimeout: Duration = .seconds(180)

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let systemProxy: SystemProxyService
    @ObservationIgnored private let kernel: KernelService
    @ObservationIgnored private let client: HelperClient

    @ObservationIgnored private var enableTask: Task<Void, Never>?
    /// `osascript` 是否真的还在跑：超时不会打断密码框，所以重入判断看这个
    /// （而不是看 Task 句柄——句柄在超时那一刻就已经结束了）
    @ObservationIgnored private var installInFlight = false
    /// 开 TUN 前的网络基线：关闭时对比，判断路由 / DNS 是否复原
    @ObservationIgnored private var baseline: SystemNetworkSnapshot?
    /// helper 内核是否**可能**在跑（spawn 已成功，但还没被 `KernelService` 接管的那段时间也算）
    @ObservationIgnored private var hasHelperKernel = false

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

    // MARK: - 派生状态

    var isOn: Bool { phase == .on }

    /// helper 侧可能仍有 root 内核在跑（含「已 spawn 但尚未接管」的窗口）。
    /// 退出清理、代理互斥都以它判断，避免漏掉那几百毫秒。
    var isHelperKernelRunning: Bool { hasHelperKernel || kernel.isExternal }

    /// 过渡态 / 授权中：磁贴禁用，忽略重复点击
    var isBusy: Bool {
        switch phase {
        case .awaitingAuthorization, .starting, .stopping: true
        case .off, .needsInstall, .on, .failed: false
        }
    }

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

    /// 磁贴点击。过渡中 / 授权中一律忽略（重复点击的边界处理）。
    func toggle() {
        switch phase {
        case .on:
            Task { [weak self] in await self?.disable() }
        case .awaitingAuthorization, .starting, .stopping:
            return
        case .off, .needsInstall, .failed:
            requestEnable()
        }
    }

    private func requestEnable() {
        guard !isBusy else { return }
        // 上一次授权窗口还没关：再点只会再起一个 osascript（两个密码框），直接拒绝
        guard !installInFlight else {
            failureMessage = "正在等待上一次授权结果，请先取消或完成那个密码框"
            return
        }
        failureMessage = nil
        restoreWarning = nil

        // 已装（且 launchd 里 job 在）→ 直接走启动；版本是否匹配在 enable 里查
        if HelperInstaller.isInstalled {
            startEnable()
            return
        }

        // 未装：先「需要授权」再弹我们自己的说明卡，确认后才可能弹系统密码框
        phase = .needsInstall(.notInstalled)
        confirmAndInstall(blocker: .notInstalled)
    }

    var isInstalling: Bool { installInFlight }

    // MARK: - 安装流程（不执行系统授权框，需用户确认）

    /// 说明卡 → 确认后调 `HelperInstaller.install()`。
    ///
    /// **本轮不执行安装**：这里只实现流程，实际点「继续」才会进 `install()`。
    private func confirmAndInstall(blocker: TunInstallBlocker) {
        guard !installInFlight else { return }

        let confirmed = TunInstallPrompt.confirm(updating: blocker == .outdated)
        guard confirmed else {
            phase = .off
            failureMessage = TunFailure.userCancelled.userMessage
            return
        }

        installInFlight = true
        Task { [weak self] in
            await self?.installThenEnable()
        }
    }

    private func installThenEnable() async {
        phase = .awaitingAuthorization
        let outcome = await awaitInstallOutcome()

        switch outcome {
        case .installed:
            // 装完不一定真跑起来：以 launchd 的 job 状态为准
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

                // 系统密码框这时才真的关了：从这里开始允许再次点击
                self.installInFlight = false

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
            await self?.enableInternal(retryingAfterInstall: false)
        }
    }

    /// 开启主流程：版本 → 互斥关代理 → 本地内核让位 → 生成正文 → 送配置 → 启动 → 就绪 → 接管端点
    private func enableInternal(retryingAfterInstall: Bool) async {
        failureMessage = nil
        restoreWarning = nil
        phase = .starting

        // 1. 协议版本：不一致就先引导更新（覆盖安装要再授权一次）
        do {
            try await client.checkVersion()
        } catch HelperClientError.versionMismatch {
            if retryingAfterInstall {
                fail(.versionMismatch)
                return
            }
            phase = .needsInstall(.outdated)
            failureMessage = "管理员组件需要更新，需再次授权"
            confirmAndInstall(blocker: .outdated)
            return
        } catch {
            if retryingAfterInstall {
                fail(.daemonNotRunning)
                return
            }
            phase = .needsInstall(.notInstalled)
            confirmAndInstall(blocker: .notInstalled)
            return
        }

        // 2. 互斥：系统代理与 TUN 不能同时接管流量
        if systemProxy.isEnabled {
            do {
                try await systemProxy.disable()
            } catch {
                fail(.startup("无法关闭系统代理，请先手动关闭"))
                return
            }
        }

        // 3. 本地内核让位：两者用同一个 mixed-port
        if kernel.phase == .running || kernel.phase == .starting {
            await kernel.stop()
        }

        // 4. 生成本轮的端点与正文（端口 / secret 由 App 决定，随正文一起送 helper）
        let ports: [Int]
        do {
            ports = try PortAllocator.allocateDistinct(2)
        } catch {
            fail(.startup("无法分配本地端口"))
            return
        }

        let mixedPort = settings.mixedPort
        guard PortAllocator.isAvailable(port: mixedPort) else {
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
            tunEnabled: true,
            tunStack: .gvisor
        )

        let profileURL = ProfileLocator.locate()
        let yaml: String
        do {
            yaml = try RuntimeConfigBuilder.yaml(from: profileURL, injected: injected)
        } catch {
            fail(.startup((error as? KernelError)?.userMessage ?? "生成运行配置失败"))
            return
        }

        // 5. 抓基线：关闭时用它判断路由 / DNS 是否复原
        baseline = SystemNetworkProbe.capture()

        // 6. 送配置 → 启动 root 内核（两步 XPC，失败时停一次防半开）
        let runner = HelperKernelRunner(client: client)
        do {
            _ = try await runner.start(configData: Data(yaml.utf8))
            hasHelperKernel = true
        } catch {
            await runner.stop()
            fail(.startup(Self.describe(error)))
            return
        }

        // 7. 等 `/version`：spawn 成功不等于可用（端口冲突 / 配置错误都在这一步暴露）
        let version: String
        do {
            version = try await waitUntilReady(port: ports[0], secret: secret)
        } catch {
            await runner.stop()
            hasHelperKernel = false
            fail(.startup("内核启动后 8 秒内未就绪"))
            return
        }

        // 8. 接管 API 端点：面板的策略组 / 流量 / 连接 / 日志都从这里取数
        kernel.adoptExternalKernel(
            port: ports[0],
            secret: secret,
            version: version,
            mixedPort: mixedPort,
            logLevel: settings.logLevel.cliValue,
            allowLAN: settings.allowLAN,
            hasProfile: profileURL != nil
        )

        phase = .on
        Self.logger.notice("TUN 已开启 controller=127.0.0.1:\(ports[0]) version=\(version, privacy: .public)")
    }

    /// 轮询 `/version`；成功即就绪
    private func waitUntilReady(port: Int, secret: String) async throws -> String {
        let probe = ClashAPIClient(port: port, secret: secret, timeout: 1)
        let deadline = ContinuousClock.now + Self.readinessTimeout
        while ContinuousClock.now < deadline {
            if let response = try? await probe.version(timeout: 1) {
                return response.version
            }
            try? await Task.sleep(for: Self.readinessPollInterval)
        }
        throw TunError.notReady
    }

    // MARK: - 关闭

    /// 关闭：`stopKernel`（XPC 等确认）→ 释放端点 → 校验默认路由 / DNS → off
    ///
    /// - Parameter restartLocalKernel: 关闭后是否把本地（用户态）内核拉回来。
    ///   默认 `true`（用户点 TUN 关掉后仍要有节点可选）；「接着要开系统代理」的路径传
    ///   `false`——那边需要自己按 `running` 等待，不能被这里的自动重启抢跑。
    func disable(restartLocalKernel: Bool = true) async {
        guard isOn || isHelperKernelRunning else { return }

        phase = .stopping
        do {
            try await client.stopKernel()
        } catch {
            // 停不掉就不能假装关掉：TUN 还在接管流量，保留端点让面板说实话
            let reason = "无法停止 TUN 内核（\(Self.describe(error))），请重试"
            phase = .failed(.startup(reason))
            failureMessage = "TUN 未关闭：\(reason)"
            return
        }

        hasHelperKernel = false
        kernel.releaseExternalKernel()

        if let baseline {
            let differences = SystemNetworkProbe.capture().differences(from: baseline)
            if !differences.isEmpty {
                restoreWarning = "已关闭 TUN，但\(differences.joined(separator: "；"))。若仍无法上网，请重启网络或重启电脑"
                Self.logger.error("TUN 关闭后网络未复原：\(differences.joined(separator: "；"), privacy: .public)")
            }
        }
        self.baseline = nil

        phase = .off
        failureMessage = nil
        Self.logger.notice("TUN 已关闭")

        // 回落：把本地内核拉回来，面板不至于没有节点可选
        if restartLocalKernel {
            await restartLocalKernelIfNeeded()
        }
    }

    // MARK: - 失败与回落

    private func fail(_ failure: TunFailure) {
        phase = .failed(failure)
        failureMessage = failure.userMessage
        hasHelperKernel = false
        kernel.releaseExternalKernel()
        Self.logger.error("TUN 失败：\(failure.userMessage, privacy: .public)")

        // 起不来就回落系统代理模式：本地内核拉回来，用户还能继续用面板
        Task { [weak self] in
            await self?.restartLocalKernelIfNeeded()
        }
    }

    private func restartLocalKernelIfNeeded() async {
        guard !kernel.isExternal, kernel.phase != .running, !kernel.isTransitioning else { return }
        // 用「盘上现在有没有配置」判断，而不是 `kernel.hasProfile`：刚删掉最后一条订阅时
        // 后者还是 true，会把内核用空配置拉起来
        guard ProfileLocator.locate() != nil else { return }
        await kernel.start()
    }

    /// 启动时清理上一次会话遗留的 root 内核（`kill -9` / 崩溃时退出清理没机会跑）。
    ///
    /// helper 是 launchd 常驻，内核是它的子进程：App 没了内核照样在接管流量，而面板显示
    /// 「已关闭」——用户会以为没开 TUN 却上不了网。这里像 `OrphanKernelReaper` 一样先清掉。
    private func reapOrphanKernelIfNeeded() {
        Task { [weak self] in
            guard let self else { return }
            // 没装组件就不去连：省一次必然失败的 XPC，也避免启动日志里出现无害的 error
            guard HelperInstaller.isInstalled else { return }
            let running = (try? await self.client.kernelState()) ?? nil
            guard let running, !self.isOn, !self.kernel.isExternal else { return }
            Self.logger.notice("发现遗留的 TUN 内核 pid=\(running, privacy: .public)，先停掉")
            try? await self.client.stopKernel()
        }
    }

    private static func describe(_ error: Error) -> String {
        if let helper = error as? HelperClientError { return helper.userMessage }
        if let kernel = error as? KernelError { return kernel.userMessage }
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
