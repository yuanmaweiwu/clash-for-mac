import AppKit
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
    private(set) var lastError: KernelError?
    private(set) var kernelVersion: String?
    /// 本次运行的 API 端口（127.0.0.1）
    private(set) var port: Int?
    /// 本次运行的 API secret；只在内存持有，不写日志
    private(set) var secret: String?
    /// 启动 / 停止过程中：UI 应禁用连接磁贴
    private(set) var isTransitioning = false

    private static let logger = Logger(subsystem: "com.clash.app", category: "kernel")
    private static let readinessTimeout: Duration = .seconds(8)
    private static let readinessPollInterval: Duration = .milliseconds(100)
    private static let readinessRequestTimeout: TimeInterval = 1
    private static let logTailLineCount = 20

    @ObservationIgnored private var runner: KernelRunner?
    @ObservationIgnored private var client: ClashAPIClient?
    @ObservationIgnored private var userInitiatedStop = false
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    init(runner: KernelRunner? = nil) {
        self.runner = runner
        runner?.onExit = { [weak self] code in
            self?.handleUnexpectedExit(code: code)
        }

        // App 退出即停（ADR-0007）：子进程不会随父进程自动结束，这里补一刀
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdownForTermination()
            }
        }
    }

    // MARK: - 启动

    func start() async {
        guard !isTransitioning, phase != .running else { return }

        isTransitioning = true
        lastError = nil
        kernelVersion = nil
        defer { isTransitioning = false }

        do {
            let binaryURL = try Self.bundledKernelURL()
            let ports = try PortAllocator.allocateDistinct(2)

            // 配置来源：CLASH_PROFILE（DEBUG）/ profiles 下唯一一份，都没有则用内置空配置
            let profileURL = ProfileLocator.locate()
            let injected = RuntimeConfigBuilder.Injected(
                controllerPort: ports[0],
                dnsPort: ports[1],
                secret: RuntimeConfigBuilder.makeSecret()
            )
            let runtimeURL = try RuntimeConfigBuilder.build(from: profileURL, injected: injected)
            Self.logger.notice("使用配置 profile=\(ProfileLocator.displayName(for: profileURL), privacy: .public)")

            // 校验通过才进 starting（core-process §4）
            try await validateConfiguration(binaryURL: binaryURL, configPath: runtimeURL)

            let runner = runner ?? makeRunner(binaryURL: binaryURL)
            phase = .starting
            let pid = try runner.start(configPath: runtimeURL)

            port = injected.controllerPort
            secret = injected.secret
            let client = ClashAPIClient(
                port: injected.controllerPort,
                secret: injected.secret,
                timeout: Self.readinessRequestTimeout
            )
            self.client = client

            Self.logger.notice("内核进程已拉起 pid=\(pid) controller=127.0.0.1:\(injected.controllerPort)")

            kernelVersion = try await waitUntilReady(client: client, runner: runner)
            phase = .running
            Self.logger.notice("内核就绪 version=\(self.kernelVersion ?? "?", privacy: .public)")
        } catch {
            await failStart(with: error)
        }
    }

    // MARK: - 停止

    func stop() async {
        guard !isTransitioning else { return }
        guard phase == .running || phase == .starting else { return }

        isTransitioning = true
        userInitiatedStop = true
        defer {
            isTransitioning = false
            userInitiatedStop = false
        }

        await runner?.stop()
        client = nil
        kernelVersion = nil
        phase = .stopped
        Self.logger.notice("内核已停止")
    }

    /// App 即将退出：只发 SIGTERM，不等待
    func shutdownForTermination() {
        userInitiatedStop = true
        runner?.terminateImmediately()
    }

    // MARK: - 失败与崩溃

    private func failStart(with error: Error) async {
        let kernelError = (error as? KernelError) ?? .configInvalid(detail: String(describing: error))

        if let runner, runner.isRunning {
            await runner.stop()
        }
        client = nil
        phase = .failed
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
        phase = .failed
        lastError = .crashed(code: code)

        Self.logger.error("内核异常退出 code=\(code)")
        logTail()

        // TODO(v0.2): helper 方案下按 1s/3s/9s 退避最多自动重启 3 次（core-process §2）；
        // v0.1 先不自动重启，避免与后续 helper 的生命周期管理冲突。
    }

    // MARK: - 就绪探测

    private func waitUntilReady(client: ClashAPIClient, runner: KernelRunner) async throws -> String {
        let deadline = ContinuousClock.now + Self.readinessTimeout
        while ContinuousClock.now < deadline {
            if !runner.isRunning {
                throw classifyStartupFailure(exitCode: runner.lastExitCode ?? -1)
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
        let outcome = await Task.detached(priority: .userInitiated) { () -> ValidationOutcome in
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

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ValidationOutcome(
                status: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
            )
        }.value

        guard outcome.status != 0 else { return }

        let tail = Self.tail(ofText: outcome.output, lines: Self.logTailLineCount, redacting: secret)
        Self.logger.error("mihomo -t 失败 exit=\(outcome.status)\n\(tail, privacy: .public)")

        if Self.looksLikeGeodataProblem(outcome.output) {
            throw KernelError.geodataUnavailable
        }
        throw KernelError.configInvalid(detail: tail)
    }

    // MARK: - 二进制定位

    /// 包内 `Contents/Resources/Kernel/mihomo`；源码目录 `Resources/Kernel/mihomo` 打包后不存在，不做回退
    private static func bundledKernelURL() throws -> URL {
        let candidates = ["Resources/Kernel", "Kernel"]
        for subdirectory in candidates {
            if let url = Bundle.main.url(forResource: "mihomo", withExtension: nil, subdirectory: subdirectory),
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        logger.error("包内找不到可执行的 mihomo（bundle=\(Bundle.main.bundlePath, privacy: .public)）")
        throw KernelError.binaryMissing
    }

    private func makeRunner(binaryURL: URL) -> KernelRunner {
        let runner = LocalKernelRunner(binaryURL: binaryURL)
        runner.onExit = { [weak self] code in
            self?.handleUnexpectedExit(code: code)
        }
        self.runner = runner
        return runner
    }

    // MARK: - 错误归类（只看日志关键字，不解析文本内容）

    private func classifyStartupFailure(exitCode: Int32) -> KernelError {
        let tail = logTailText()
        if tail.contains("address already in use") {
            return .portInUse
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
        guard let url = runner?.logFileURL else { return "" }
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
        phase = .failed
        lastError = error
    }
    #endif
}
