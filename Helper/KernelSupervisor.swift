import Darwin
import Foundation
import OSLog

/// 一个命令的结果：`ok == false` 时 `message` 是给用户看的原因。
struct KernelCommandResult: Sendable {
    let ok: Bool
    let message: String?

    static func success(_ message: String? = nil) -> KernelCommandResult {
        KernelCommandResult(ok: true, message: message)
    }

    static func failure(_ message: String) -> KernelCommandResult {
        KernelCommandResult(ok: false, message: message)
    }
}

/// helper 内唯一的 mihomo 持有者（`core-process` §2 进程模型）。
///
/// 只做三件事：以 root spawn、单实例、`SIGTERM` → 3s → `SIGKILL`。
/// 不解析、不转发配置；配置与二进制路径都从 `HelperLayout` 推导，调用方无法指定。
///
/// 线程模型：所有状态都在私有串行队列上，对外方法用 `queue.sync`。
/// XPC 方法本身跑在各自连接的私有队列上，所以这里不会自锁；单次阻塞上限 = 停止宽限 3s。
final class KernelSupervisor: @unchecked Sendable {

    static let shared = KernelSupervisor()

    private static let logger = Logger(subsystem: "com.clash.helper", category: "kernel")
    /// `SIGTERM` 后的宽限（`core-process` §2）
    private static let terminationGrace: TimeInterval = 3
    private static let killGrace: TimeInterval = 1
    private static let pollInterval: TimeInterval = 0.05
    /// spawn 后先观察一小会儿，把「立刻退出」变成可读的失败原因，而不是假装成功
    private static let spawnProbeInterval: TimeInterval = 0.25

    private let queue = DispatchQueue(label: "com.clash.helper.kernel")
    private var process: Process?
    private var logHandle: FileHandle?

    // MARK: - 对外

    func start() -> KernelCommandResult {
        queue.sync { startLocked() }
    }

    func stop() -> Bool {
        queue.sync { stopLocked() }
    }

    func state() -> (running: Bool, pid: String?) {
        queue.sync {
            guard let process else { return (false, nil) }
            let pid = process.processIdentifier
            guard process.isRunning else { return (false, nil) }
            return (true, String(pid))
        }
    }

    // MARK: - 启动

    private func startLocked() -> KernelCommandResult {
        // 单实例：已有实例在跑就回报既有 pid，绝不重复 spawn
        if let process, process.isRunning {
            let pid = process.processIdentifier
            Self.logger.notice("内核已在运行，复用 pid=\(pid)")
            return .success("pid=\(pid)")
        }
        closeLog()

        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: HelperLayout.kernelToolPath) else {
            Self.logger.error("内核不存在或不可执行：\(HelperLayout.kernelToolPath, privacy: .public)")
            return .failure("内核文件缺失，请重新安装组件")
        }
        guard fileManager.fileExists(atPath: HelperLayout.runtimeConfigPath) else {
            Self.logger.error("运行配置缺失：\(HelperLayout.runtimeConfigPath, privacy: .public)")
            return .failure("运行配置缺失，请重新开启 TUN")
        }

        let handle: FileHandle
        do {
            handle = try openLogHandle()
        } catch {
            Self.logger.error("打开内核日志失败：\(String(describing: error), privacy: .public)")
            return .failure("无法写入内核日志")
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: HelperLayout.kernelToolPath)
        child.arguments = [
            "-d", HelperLayout.supportDirectory,
            "-f", HelperLayout.runtimeConfigPath,
        ]
        child.currentDirectoryURL = URL(fileURLWithPath: HelperLayout.supportDirectory, isDirectory: true)
        child.standardOutput = handle
        child.standardError = handle
        child.standardInput = FileHandle.nullDevice

        do {
            try child.run()
        } catch {
            try? handle.close()
            Self.logger.error("spawn 失败：\(String(describing: error), privacy: .public)")
            return .failure("无法启动内核（spawn 失败）")
        }

        let pid = child.processIdentifier
        process = child
        logHandle = handle
        Self.logger.notice("以 root 启动内核 pid=\(pid)")

        // 立刻退出的多半是配置 / 端口 / 权限问题，读日志末行给出可读原因
        Thread.sleep(forTimeInterval: Self.spawnProbeInterval)
        guard child.isRunning else {
            let code = child.terminationStatus
            let tail = logTail()
            Self.logger.error("内核启动后立即退出 code=\(code)")
            closeLog()
            process = nil
            return .failure(tail.isEmpty ? "内核启动失败（退出码 \(code)）" : tail)
        }
        return .success("pid=\(pid)")
    }

    // MARK: - 停止

    private func stopLocked() -> Bool {
        guard let process else {
            closeLog()
            return true
        }

        var stopped = true
        if process.isRunning {
            process.terminate() // SIGTERM
            if !waitForExit(process, within: Self.terminationGrace) {
                Self.logger.warning("SIGTERM 超时，改用 SIGKILL pid=\(process.processIdentifier)")
                kill(process.processIdentifier, SIGKILL)
                stopped = waitForExit(process, within: Self.killGrace)
            }
        }

        Self.logger.notice("内核已停止（\(stopped ? "确认退出" : "未能退出", privacy: .public)）")
        self.process = nil
        closeLog()
        return stopped
    }

    // MARK: - 内部

    private func waitForExit(_ process: Process, within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return true }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        return !process.isRunning
    }

    /// 日志 0600 root：里面可能有节点地址，不给其他用户读
    private func openLogHandle() throws -> FileHandle {
        let path = HelperLayout.kernelLogPath
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        return handle
    }

    private func closeLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    /// 启动失败时读日志末几行（只进 XPC 回复，不写系统日志）
    private func logTail() -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: HelperLayout.kernelLogPath)) else {
            return ""
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let readSize = min(size, 16 * 1024)
        _ = try? handle.seek(toOffset: size - readSize)
        let data = (try? handle.readToEnd()) ?? Data()
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(3)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let joined = lines.joined(separator: " / ")
        // 这条会原样出现在 XPC 回复里（App 可能直接展示），截断避免把整段日志塞进 UI
        return joined.count > 300 ? String(joined.prefix(300)) + "…" : joined
    }
}
