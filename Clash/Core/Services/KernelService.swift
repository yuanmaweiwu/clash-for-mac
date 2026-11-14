import Darwin
import Foundation
import OSLog

/// 内核生命周期与状态（`docs/01-ARCHITECTURE.md` §3 的唯一状态源）。
///
/// v0.1 走 `LocalKernelRunner`（App 用户态进程，ADR-0007）；helper 落地后只换 runner。
/// 只负责「启动 → /version 就绪 → 停止 / 崩溃」，不碰代理、节点、订阅。
@MainActor
@Observable
final class KernelService {

    // MARK: - 对 UI 暴露的状态

    private(set) var phase: KernelPhase = .stopped
    /// 相位变化回调：面板据此在内核 `running` 后刷新 `/proxies`、`stopped` 后回到空态。
    /// 单订阅者（`PanelPreviewModel`），只在主线程触发。
    @ObservationIgnored var onPhaseChange: ((KernelPhase) -> Void)?
    private(set) var lastError: KernelError?
    private(set) var kernelVersion: String?
    /// 本次运行的 API 端口（127.0.0.1）
    private(set) var port: Int?
    /// 本次运行的 API secret；只在内存持有，不写日志
    private(set) var secret: String?
    /// 本次运行实际注入的 mixed-port / log-level / allow-lan：设置窗口据此判断「需要重启内核生效」
    private(set) var activeMixedPort: Int?
    private(set) var activeLogLevel: String?
    private(set) var activeAllowLAN: Bool?
    /// 本轮启动是否用了用户配置（false = 内置空配置），空态文案据此区分
    private(set) var hasProfile = false
    /// 启动 / 停止过程中：UI 应禁用连接磁贴
    private(set) var isTransitioning = false

    /// 内核由 helper（root）持有（TUN 模式）：App 只接管 API 端点，绝不 spawn / kill。
    /// 为真时 `start()` / `stop()` / `shutdownForTermination()` 全部让位给 `TunService`。
    private(set) var isExternal = false

    private static let logger = Logger(subsystem: "com.clash.app", category: "kernel")
    private static let readinessTimeout: Duration = .seconds(8)
    private static let readinessPollInterval: Duration = .milliseconds(100)
    private static let readinessRequestTimeout: TimeInterval = 1
    private static let logTailLineCount = 20
    /// 启动流水线（不含下载）的硬上限：超过即判定 `startTimeout`
    private static let pipelineTimeout: Duration = .seconds(20)
    /// `mihomo -t` 自身的上限：卡住就杀，不能无限等
    private static let configValidationTimeout: TimeInterval = 10

    /// 内核 / geodata 的按需下载（ADR-0012）；全局唯一，TUN 安装与订阅校验共用同一并发锁
    @ObservationIgnored let provisioner = KernelProvisioner.shared
    @ObservationIgnored private var runner: KernelRunner?
    @ObservationIgnored private var client: ClashAPIClient?
    @ObservationIgnored private var userInitiatedStop = false
    /// 设置来源：端口 / 日志级别 / 局域网访问都从这里取，`KernelService` 不再写死 7890
    @ObservationIgnored let settings: SettingsStore

    init(runner: KernelRunner? = nil, settings: SettingsStore = SettingsStore()) {
        self.runner = runner
        self.settings = settings
        runner?.onExit = { [weak self] code in
            self?.handleUnexpectedExit(code: code)
        }
        // 退出清理（含「先还原系统代理再发 SIGTERM」的顺序）统一由
        // `AppTerminationGuard` 负责，本类只提供 `shutdownForTermination()`。
    }

    // MARK: - 相位

    /// 唯一写相位的地方：改完通知订阅者（面板据此刷新或清空代理数据）
    private func setPhase(_ newPhase: KernelPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        onPhaseChange?(newPhase)
    }

    // MARK: - 启动

    func start() async {
        guard !isTransitioning, phase != .running else { return }
        // TUN 内核已由 helper 持有：本地再起一个会抢同一个 mixed-port
        guard !isExternal else { return }

        isTransitioning = true
        lastError = nil
        kernelVersion = nil
        defer { isTransitioning = false }

        do {
            try await performStart()
        } catch {
            // 占用者是本产品自己留下的内核（DerivedData / 另一份拷贝 / 强杀残留）：回收后
            // 自动重试一次，不该让用户为我们的孤儿买单。别家进程占用才需要用户动手。
            guard let kernelError = error as? KernelError,
                  case .portInUse(_, let occupant) = kernelError,
                  occupant?.isProductKernel == true,
                  await reapProductKernelAndWaitForPort() else {
                await failStart(with: error)
                return
            }
            Self.logger.notice("占用端口的本产品内核已回收，重试启动一次")
            do {
                try await performStart()
            } catch {
                await failStart(with: error)
            }
        }
    }

    /// 一次完整的启动尝试：确保内核 → 确保 geodata → 启动流水线（带 20s 看门狗）。
    private func performStart() async throws {
        // 包内不再带二进制（ADR-0012）：先确保内核已下载并通过校验，UI 在此期间显示下载进度
        setPhase(.starting)

        Self.logger.notice("启动步骤 1/2：ensureKernel begin")
        let binaryURL = try await provisioner.ensureKernel()
        Self.logger.notice("启动步骤 1/2：ensureKernel end")
        try Task.checkCancellation()

        // 配置来源：CLASH_PROFILE（DEBUG）/ profiles 下唯一一份，都没有则用内置空配置
        let profileURL = ProfileLocator.locate()
        hasProfile = profileURL != nil
        // `GEOIP,` / `GEOSITE,` 规则需要 geodata；包内不再附带，缺失时先下载（ADR-0012）
        if await TunGeodataProbe.profileNeedsGeodata(profileURL) {
            Self.logger.notice("启动步骤 2/2：ensureGeodata begin")
            try await provisioner.ensureGeodata()
            Self.logger.notice("启动步骤 2/2：ensureGeodata end")
            try Task.checkCancellation()
        }

        try await runPipelineWithDeadline(binaryURL: binaryURL, profileURL: profileURL)
    }

    /// 启动流水线：孤儿回收 → 端口确认 → 配置生成校验 → 拉起 → 等就绪。
    ///
    /// 整段有 20 秒看门狗（`pipelineTimeout`）：任何一步永久 await 都会被判定 `startTimeout`，
    /// 而不是让面板永远停在「启动中」。
    private func runPipelineWithDeadline(binaryURL: URL, profileURL: URL?) async throws {
        let outcome = PipelineOutcome()
        let task = Task { @MainActor in
            do {
                try await self.performPipeline(binaryURL: binaryURL, profileURL: profileURL)
                outcome.result = .success(())
            } catch {
                outcome.result = .failure(error)
            }
        }

        let deadline = ContinuousClock.now + Self.pipelineTimeout
        while outcome.result == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard let result = outcome.result else {
            Self.logger.error(
                "启动流水线超过 \(Int(Self.pipelineTimeout.components.seconds)) 秒未到 running，判定超时"
            )
            task.cancel()
            provisioner.cancelInFlight()
            await runner?.stop()
            throw KernelError.startTimeout
        }
        try result.get()
    }

    private func performPipeline(binaryURL: URL, profileURL: URL?) async throws {
        try Task.checkCancellation()

        // 强杀兜底：`SIGKILL` / 系统强杀时 `AppTerminationGuard` 没机会跑，旧内核会被
        // launchd 收留并继续占着 mixed-port。判据是「本产品的任意构建」（见
        // `KernelProcessIdentity`），DerivedData 里跑过的版本也会被收掉。
        // 正常退出 / SIGTERM 路径不经过这里（那条路已由 `AppTerminationGuard` 处理）。
        Self.logger.notice("流水线步骤 reap begin")
        await OrphanKernelReaper.reapOrphans()
        Self.logger.notice("流水线步骤 reap end")
        try Task.checkCancellation()

        // 清完孤儿仍被占 → 是别的程序占着（或孤儿杀不掉）：报 portInUse 并带上占用者，不硬起
        let mixedPort = settings.mixedPort
        try await ensurePortAvailable(mixedPort)
        try Task.checkCancellation()

        let ports = try PortAllocator.allocateDistinct(2)

        let injected = RuntimeConfigBuilder.Injected(
            mixedPort: mixedPort,
            allowLAN: settings.allowLAN,
            controllerPort: ports[0],
            dnsPort: ports[1],
            secret: RuntimeConfigBuilder.makeSecret(),
            logLevel: settings.logLevel.cliValue,
            mode: settings.mode
        )
        let runtimeURL = try await RuntimeConfigBuilder.build(from: profileURL, injected: injected)
        Self.logger.notice("使用配置 profile=\(ProfileLocator.displayName(for: profileURL), privacy: .public)")
        try Task.checkCancellation()

        // 校验通过才进 starting（core-process §4）
        Self.logger.notice("流水线步骤 -t begin")
        try await validateConfiguration(binaryURL: binaryURL, configPath: runtimeURL)
        Self.logger.notice("流水线步骤 -t end")
        try Task.checkCancellation()

        let runner = runner ?? makeRunner(binaryURL: binaryURL)
        Self.logger.notice("流水线步骤 spawn begin")
        let pid = try await runner.start(configPath: runtimeURL)
        Self.logger.notice("流水线步骤 spawn end pid=\(pid)")

        port = injected.controllerPort
        secret = injected.secret
        let client = ClashAPIClient(
            port: injected.controllerPort,
            secret: injected.secret,
            timeout: Self.readinessRequestTimeout
        )
        self.client = client

        Self.logger.notice("内核进程已拉起 pid=\(pid) controller=127.0.0.1:\(injected.controllerPort)")

        Self.logger.notice("流水线步骤 ready begin")
        kernelVersion = try await waitUntilReady(client: client, runner: runner, mixedPort: injected.mixedPort)
        try Task.checkCancellation()
        Self.logger.notice("流水线步骤 ready end")
        activeMixedPort = injected.mixedPort
        activeLogLevel = injected.logLevel
        activeAllowLAN = injected.allowLAN
        setPhase(.running)
        Self.logger.notice("内核就绪 version=\(self.kernelVersion ?? "?", privacy: .public)")
    }

    /// 端口空闲则直接过；被占就诊断占用者并抛 `portInUse`（文案带 pid / 名称）
    private func ensurePortAvailable(_ port: Int) async throws {
        if PortAllocator.isAvailable(port: port) { return }

        let occupant = await PortOccupantProbe.listener(onPort: port)
        Self.logger.error(
            "mixed-port \(port) 被占用：\(occupant?.summary ?? "未知进程", privacy: .public) path=\(occupant?.executablePath ?? "未知", privacy: .public)"
        )
        throw KernelError.portInUse(port: port, occupant: occupant)
    }

    /// 回收本产品内核后短暂等端口释放；返回端口是否已可用
    private func reapProductKernelAndWaitForPort() async -> Bool {
        await OrphanKernelReaper.reapOrphans()
        return await waitForPort(settings.mixedPort, within: .seconds(2))
    }

    private func waitForPort(_ port: Int, within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if PortAllocator.isAvailable(port: port) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return PortAllocator.isAvailable(port: port)
    }

    // MARK: - 停止

    func stop() async {
        guard !isTransitioning else { return }
        guard phase == .running || phase == .starting else { return }
        // 外部（TUN）内核只能由 `TunService` 通过 XPC 停：这里发不了信号
        guard !isExternal else { return }

        isTransitioning = true
        userInitiatedStop = true
        defer {
            isTransitioning = false
            userInitiatedStop = false
        }

        await runner?.stop()
        client = nil
        kernelVersion = nil
        activeMixedPort = nil
        activeLogLevel = nil
        activeAllowLAN = nil
        setPhase(.stopped)
        Self.logger.notice("内核已停止")
    }

    /// App 即将退出：只发 SIGTERM，不等待。
    /// 由 `AppTerminationGuard` 在 `applicationWillTerminate` 与信号路径里调用，必须排在
    /// 系统代理还原之后（`core-process` §3）。
    ///
    /// TUN 模式下进程不在本 App 里：`AppTerminationGuard` 会先走
    /// `HelperClient.stopKernelSynchronously`，这里什么都不做。
    func shutdownForTermination() {
        guard !isExternal else { return }
        userInitiatedStop = true
        runner?.terminateImmediately()
    }

    // MARK: - 外部内核（TUN / helper）

    /// 内核下载 / 校验进度（面板据此显示「正在下载内核…」与重试，ADR-0012）
    var provisioningPhase: KernelProvisioner.Phase { provisioner.phase }

    /// TUN 安装 / 启动前确保内核已就位（缺则下载）；失败抛 `KernelProvisionError`
    func ensureKernelAvailable() async throws {
        _ = try await provisioner.ensureKernel()
    }

    /// 订阅里有 `GEOIP,` / `GEOSITE,` 规则时确保 geodata 已下载
    func ensureGeodataIfNeeded() async throws {
        guard await TunGeodataProbe.profileNeedsGeodata(ProfileLocator.locate()) else { return }
        try await provisioner.ensureGeodata()
    }

    /// helper 已启动 root 内核且 `/version` 就绪：App 接管 API 端点。
    ///
    /// 所有读 API 的服务（策略组 / 流量 / 连接 / 日志）都从 `port` + `secret` 推导客户端，
    /// 因此换上端点并进 `running` 后，面板看到的就是 TUN 内核的真实数据，无需各处特判。
    func adoptExternalKernel(
        port: Int,
        secret: String,
        version: String,
        mixedPort: Int,
        logLevel: String,
        allowLAN: Bool,
        hasProfile: Bool
    ) {
        isExternal = true
        self.port = port
        self.secret = secret
        kernelVersion = version
        activeMixedPort = mixedPort
        activeLogLevel = logLevel
        activeAllowLAN = allowLAN
        self.hasProfile = hasProfile
        client = ClashAPIClient(port: port, secret: secret)
        lastError = nil
        setPhase(.running)
        Self.logger.notice("接管 TUN 内核 controller=127.0.0.1:\(port)")
    }

    /// TUN 已停：丢掉端点并回到 `stopped`（不发信号、不清用户配置状态）
    func releaseExternalKernel() {
        guard isExternal else { return }
        isExternal = false
        client = nil
        port = nil
        secret = nil
        kernelVersion = nil
        activeMixedPort = nil
        activeLogLevel = nil
        activeAllowLAN = nil
        setPhase(.stopped)
        Self.logger.notice("TUN 内核端点已释放")
    }

    // MARK: - 失败与崩溃

    private func failStart(with error: Error) async {
        let kernelError: KernelError
        if let known = error as? KernelError {
            kernelError = known
        } else if let provision = error as? KernelProvisionError {
            kernelError = .provisioning(provision)
        } else {
            kernelError = .configInvalid(detail: String(describing: error))
        }

        if let runner, runner.isRunning {
            await runner.stop()
        }
        client = nil
        activeMixedPort = nil
        activeLogLevel = nil
        activeAllowLAN = nil
        setPhase(.failed)
        lastError = kernelError

        Self.logger.error("内核启动失败：\(kernelError.logDescription, privacy: .public)")
        logTail()
    }

    /// 非用户停止的退出 → crashed，v0.1 不自动重启
    private func handleUnexpectedExit(code: Int32) {
        guard !userInitiatedStop, !isTransitioning else { return }
        guard phase == .running || phase == .starting else { return }

        client = nil
        kernelVersion = nil
        activeMixedPort = nil
        activeLogLevel = nil
        activeAllowLAN = nil
        setPhase(.failed)
        lastError = .crashed(code: code)

        Self.logger.error("内核异常退出 code=\(code)")
        logTail()

        // TODO(v0.2): helper 方案下按 1s/3s/9s 退避最多自动重启 3 次（core-process §2）；
        // v0.1 先不自动重启，避免与后续 helper 的生命周期管理冲突。
    }

    // MARK: - 就绪探测

    private func waitUntilReady(client: ClashAPIClient, runner: KernelRunner, mixedPort: Int) async throws -> String {
        let deadline = ContinuousClock.now + Self.readinessTimeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if !runner.isRunning {
                throw await classifyStartupFailure(exitCode: runner.lastExitCode ?? -1, mixedPort: mixedPort)
            }
            if let version = try? await client.version(timeout: Self.readinessRequestTimeout) {
                return version.version
            }
            try? await Task.sleep(for: Self.readinessPollInterval)
        }
        throw KernelError.startTimeout
    }

    // MARK: - 配置校验

    private struct ValidationOutcome: Sendable {
        let status: Int32
        let output: String
    }

    private func validateConfiguration(binaryURL: URL, configPath: URL) async throws {
        let directory = AppPaths.kernelDirectory
        let timeout = Self.configValidationTimeout
        let outcome = await Task.detached(priority: .userInitiated) { () async -> ValidationOutcome in
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = ["-t", "-d", directory.path, "-f", configPath.path]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                return ValidationOutcome(status: -1, output: error.localizedDescription)
            }

            // `-t` 正常几十毫秒；卡住（例如同一工作目录的 cache.db 被另一个内核锁住）必须杀掉
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(for: .milliseconds(500))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return ValidationOutcome(status: -2, output: "mihomo -t 超时（\(Int(timeout)) 秒）")
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ValidationOutcome(
                status: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
            )
        }.value

        guard outcome.status != 0 else { return }

        // 超时单独归类：不要把「-t 卡住」说成配置错误
        if outcome.status == -2 {
            Self.logger.error("mihomo -t 超时，已终止校验进程")
            throw KernelError.startTimeout
        }

        let tail = Self.tail(ofText: outcome.output, lines: Self.logTailLineCount, redacting: secret)
        Self.logger.error("mihomo -t 失败 exit=\(outcome.status)\n\(tail, privacy: .public)")

        if Self.looksLikeGeodataProblem(outcome.output) {
            throw KernelError.geodataUnavailable
        }
        throw KernelError.configInvalid(detail: tail)
    }

    // MARK: - 二进制定位

    private func makeRunner(binaryURL: URL) -> KernelRunner {
        let runner = LocalKernelRunner(binaryURL: binaryURL)
        runner.onExit = { [weak self] code in
            self?.handleUnexpectedExit(code: code)
        }
        self.runner = runner
        return runner
    }

    // MARK: - 错误归类（只看日志关键字，不解析文本内容）

    private func classifyStartupFailure(exitCode: Int32, mixedPort: Int) async -> KernelError {
        let tail = logTailText()
        if tail.contains("address already in use") {
            // 端口在「预检」与「真正绑定」之间被抢：这里补一次占用者诊断
            let occupant = await PortOccupantProbe.listener(onPort: mixedPort)
            return .portInUse(port: mixedPort, occupant: occupant)
        }
        if Self.looksLikeGeodataProblem(tail) {
            return .geodataUnavailable
        }
        return .crashed(code: exitCode)
    }

    private static func looksLikeGeodataProblem(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("can't find mmdb") || lower.contains("mmdb download") || lower.contains("geodata download") {
            return true
        }
        return lower.contains("geodata") && (lower.contains("failed") || lower.contains("error"))
    }

    // MARK: - 日志

    private func logTail() {
        let text = logTailText()
        guard !text.isEmpty else { return }
        Self.logger.error("内核日志末 \(Self.logTailLineCount) 行：\n\(text, privacy: .public)")
    }

    private func logTailText() -> String {
        guard let runner, let url = runner.logFileURL else { return "" }
        return Self.tail(of: url, lines: Self.logTailLineCount, redacting: secret)
    }

    /// 读日志文件末尾，secret 一律打码
    private static func tail(of url: URL, lines: Int, redacting secret: String?) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let readSize = min(size, UInt64(64 * 1024))
        _ = try? handle.seek(toOffset: size - readSize)
        let data = (try? handle.readToEnd()) ?? Data()
        return tail(ofText: String(decoding: data, as: UTF8.self), lines: lines, redacting: secret)
    }

    private static func tail(ofText text: String, lines: Int, redacting secret: String?) -> String {
        var text = text
        if let secret, !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "***")
        }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        return rows.suffix(lines).joined(separator: "\n")
    }

    #if DEBUG
    /// Preview / 调试夹具：直接摆出失败态，不启动任何进程
    func applyPreviewFailure(_ error: KernelError = .binaryMissing) {
        setPhase(.failed)
        lastError = error
    }
    #endif
}

/// 启动流水线的一次性结果盒：`start()` 用轮询看门狗等它，避免 "await 一个永不结束的 Task"。
@MainActor
private final class PipelineOutcome {
    var result: Result<Void, Error>?
}
