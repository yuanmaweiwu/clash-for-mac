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

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard HelperClientValidator.isAllowed(newConnection) else {
            HelperLog.error("拒绝 XPC 连接：\(HelperClientValidator.describe(newConnection))")
            newConnection.invalidate()
            return false
        }

        HelperLog.notice("接受 XPC 连接：\(HelperClientValidator.describe(newConnection))")

        newConnection.exportedInterface = NSXPCInterface(with: KernelHelperProtocol.self)
        newConnection.exportedObject = HelperSession()
        newConnection.invalidationHandler = {
            HelperLog.notice("XPC 连接已失效")
        }
        newConnection.resume()
        return true
    }
}

/// 单个连接的导出对象：五个白名单方法，全部转给 `KernelSupervisor` / `RuntimeConfigWriter`。
///
/// 唯一从 XPC 进来的内容是「配置正文」，落盘路径由 helper 自己推导（`HelperLayout`）。
final class HelperSession: NSObject, KernelHelperProtocol {

    /// 版本 + 运行时自检（内核二进制 / 运行配置 / 运行目录）。旧 App 仍能当纯版本号解析。
    func ping(_ reply: @escaping (String) -> Void) {
        let snapshot = HelperRuntimeSnapshot.current()
        HelperLog.notice("ping → \(snapshot.wireValue)")
        reply(snapshot.wireValue)
    }

    func applyRuntimeConfig(_ bytes: Data, reply: @escaping (Bool, String?) -> Void) {
        let result = RuntimeConfigWriter.apply(bytes)
        reply(result.ok, result.message)
    }

    func startKernel(_ reply: @escaping (Bool, String?) -> Void) {
        let result = KernelSupervisor.shared.start()
        if !result.ok {
            HelperLog.error("startKernel 失败：\(result.message ?? "未知原因")")
        }
        reply(result.ok, result.message)
    }

    func stopKernel(_ reply: @escaping (Bool) -> Void) {
        let stopped = KernelSupervisor.shared.stop()
        HelperLog.notice("stopKernel → \(stopped ? "已确认退出" : "未能退出")")
        reply(stopped)
    }

    func kernelState(_ reply: @escaping (Bool, String?) -> Void) {
        let state = KernelSupervisor.shared.state()
        reply(state.running, state.pid)
    }
}
