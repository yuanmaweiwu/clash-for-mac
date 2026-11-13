import Darwin
import Foundation
import OSLog

/// helper 的日志：**unified log + 文件双写**。
///
/// 为什么必须自己写文件：`os.Logger` 只进 unified logging，**不会**写 stdout，
/// 所以 LaunchDaemon plist 里的 `StandardOutPath`（`helper.log`）永远是 0 字节
/// ——真机实测就是 0 字节，出问题时完全没法排障。
///
/// 边界：
/// - 文件写入 best-effort：打不开 / 写失败只影响文件副本，绝不影响 XPC 主流程
/// - 0600 root:wheel：日志里有内核 pid、配置路径、错误尾部（可能含节点地址）
/// - 超过 2 MB 整体截断：helper 是常驻进程，不能让日志无限增长
/// - 所有写入串行化到私有队列：XPC 方法跑在各自连接的队列上，不互相插队
enum HelperLog {

    private static let logger = Logger(subsystem: "com.clash.helper", category: "log")
    private static let maxBytes = 2 * 1024 * 1024
    private static let queue = DispatchQueue(label: "com.clash.helper.log")

    static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        appendToFile(level: "info", message)
    }

    static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        appendToFile(level: "warn", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        appendToFile(level: "error", message)
    }

    /// 每行现建（日志量很小；`ISO8601DateFormatter` 不是 Sendable，不适合做 static let）
    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: - 文件

    private static func appendToFile(level: String, _ message: String) {
        let line = "\(timestamp()) [\(level)] \(message)\n"
        queue.async {
            append(line)
        }
    }

    private static func append(_ line: String) {
        let path = HelperLayout.helperLogPath
        ensureDirectory()

        var descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if descriptor < 0 {
            // 目录 / 文件权限不对时退一步：重建一次目录再试（常见于旧版安装）
            ensureDirectory(force: true)
            descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        }
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        if currentSize(path) > maxBytes {
            _ = truncate(path, 0)
        }

        line.withCString { pointer in
            _ = Darwin.write(descriptor, pointer, strlen(pointer))
        }
    }

    private static func currentSize(_ path: String) -> Int64 {
        var info = stat()
        guard stat(path, &info) == 0 else { return 0 }
        return Int64(info.st_size)
    }

    private static func ensureDirectory(force: Bool = false) {
        let path = HelperLayout.supportDirectory
        let fileManager = FileManager.default
        if force || !fileManager.fileExists(atPath: path) {
            try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                ofItemAtPath: path
            )
        }
    }
}
