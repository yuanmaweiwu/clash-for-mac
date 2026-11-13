import Foundation
import OSLog

/// v0.1 的内核实现：App 以登录用户身份用 `Process` 直接启动包内 mihomo（ADR-0007）。
///
/// 无 root、无 TUN、无系统代理；App 退出时由 `terminateImmediately()` 结束内核。
@MainActor
final class LocalKernelRunner: KernelRunner {

    private static let logger = Logger(subsystem: "com.clash.app", category: "kernel")
    private static let terminationGrace: Duration = .seconds(3)
    private static let killGrace: Duration = .seconds(1)
    private static let pollInterval: Duration = .milliseconds(50)

    private let binaryURL: URL
    private let kernelDirectory: URL
    let logFileURL: URL

    private var process: Process?
    private var logHandle: FileHandle?

    private(set) var lastExitCode: Int32?
    var onExit: ((Int32) -> Void)?

    init(binaryURL: URL, kernelDirectory: URL = AppPaths.kernelDirectory, logFileURL: URL = AppPaths.logFileURL()) {
        self.binaryURL = binaryURL
        self.kernelDirectory = kernelDirectory
        self.logFileURL = logFileURL
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    @discardableResult
    func start(configPath: URL) throws -> Int32 {
        if let process, process.isRunning {
            return process.processIdentifier
        }
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw KernelError.binaryMissing
        }

        let handle = try openLogHandle()
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["-d", kernelDirectory.path, "-f", configPath.path]
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(code: code)
            }
        }

        do {
            try process.run()
        } catch {
            try? handle.close()
            throw KernelError.binaryMissing
        }

        self.process = process
        self.logHandle = handle
        self.lastExitCode = nil
        Self.logger.notice("启动 mihomo pid=\(process.processIdentifier) log=\(self.logFileURL.lastPathComponent, privacy: .public)")
        return process.processIdentifier
    }

    func stop() async {
        guard let process else {
            try? logHandle?.close()
            logHandle = nil
            return
        }

        if process.isRunning {
            process.terminate() // SIGTERM
            let exited = await waitForExit(process, within: Self.terminationGrace)
            if !exited {
                Self.logger.warning("SIGTERM 超时，改用 SIGKILL pid=\(process.processIdentifier)")
                kill(process.processIdentifier, SIGKILL)
                _ = await waitForExit(process, within: Self.killGrace)
            }
        }

        self.process = nil
        lastExitCode = nil
        try? logHandle?.close()
        logHandle = nil
    }

    func terminateImmediately() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    // MARK: - 内部

    private func handleTermination(code: Int32) {
        lastExitCode = code
        let hadProcess = process != nil
        process = nil
        try? logHandle?.close()
        logHandle = nil
        guard hadProcess else { return }
        Self.logger.notice("mihomo 退出 code=\(code)")
        onExit?(code)
    }

    /// 轮询等待退出；`true` = 已退出
    private func waitForExit(_ process: Process, within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !process.isRunning { return true }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return !process.isRunning
    }

    private func openLogHandle() throws -> FileHandle {
        let url = logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}
