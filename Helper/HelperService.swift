import Darwin
import Foundation
import OSLog

/// 无签名身份下的弱校验（`adr/0008` §XPC 连接校验）。
///
/// 取 XPC 连接自带的进程身份（由内核在连接建立时填写，客户端伪造不了）→ 反查可执行路径，
/// 必须落在 `<任意目录>/Clash.app/Contents/MacOS/Clash`。不足：没有 team id 可校，任何把
/// 自己放到同名路径下的程序都能通过——自用场景接受，见 ADR 里「弱校验」一节。
enum HelperClientValidator {

    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    /// - Parameter connection: 必须是 listener 刚接到的连接（此时属性是可信的）
    static func isAllowed(_ connection: NSXPCConnection) -> Bool {
        // root 自己（或系统上下文）不该连我们：App 永远是普通用户
        guard connection.effectiveUserIdentifier != 0 else { return false }

        let pid = connection.processIdentifier
        guard pid > 0 else { return false }
        guard let path = executablePath(of: pid) else { return false }

        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return canonical.hasSuffix(HelperLayout.allowedClientPathSuffix)
    }

    /// 仅供日志：连接被拒时把 pid / 路径打出来，便于排障
    static func describe(_ connection: NSXPCConnection) -> String {
        let pid = connection.processIdentifier
        let path = executablePath(of: pid) ?? "?"
        return "pid=\(pid) uid=\(connection.effectiveUserIdentifier) path=\(path)"
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

/// `NSXPCListener` 的 delegate：只放行来自本 App 的连接，并按连接发一个 session 对象。
final class HelperService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.clash.helper", category: "xpc")

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard HelperClientValidator.isAllowed(newConnection) else {
            Self.logger.error("拒绝 XPC 连接：\(HelperClientValidator.describe(newConnection), privacy: .public)")
            newConnection.invalidate()
            return false
        }

        Self.logger.notice("接受 XPC 连接：\(HelperClientValidator.describe(newConnection), privacy: .public)")

        newConnection.exportedInterface = NSXPCInterface(with: KernelHelperProtocol.self)
        newConnection.exportedObject = HelperSession()
        newConnection.invalidationHandler = {
            Self.logger.notice("XPC 连接已失效")
        }
        newConnection.resume()
        return true
    }
}

/// 单个连接的导出对象：四个白名单方法，全部转给 `KernelSupervisor`。
///
/// 不做参数校验——因为没有参数可校（路径、命令行都不经 XPC）。
final class HelperSession: NSObject, KernelHelperProtocol {

    func ping(_ reply: @escaping (String) -> Void) {
        reply(String(HelperVersion))
    }

    func startKernel(_ reply: @escaping (Bool, String?) -> Void) {
        let result = KernelSupervisor.shared.start()
        reply(result.ok, result.message)
    }

    func stopKernel(_ reply: @escaping (Bool) -> Void) {
        reply(KernelSupervisor.shared.stop())
    }

    func kernelState(_ reply: @escaping (Bool, String?) -> Void) {
        let state = KernelSupervisor.shared.state()
        reply(state.running, state.pid)
    }
}
