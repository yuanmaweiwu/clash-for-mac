import Foundation
import OSLog

/// helper XPC 客户端的错误（`core-process` §7：`helperNotInstalled` / `permissionDenied`）
enum HelperClientError: Error, Equatable, Sendable {
    /// 连不上 mach service：没装、没被 launchd 拉起、或被 helper 拒了
    case helperNotInstalled
    /// App 与 helper 的协议版本不一致 → 需要覆盖安装
    case versionMismatch(expected: Int, actual: Int?)
    /// helper 明确回了失败（参数是 helper 给出的原因）
    case helperRejected(reason: String)

    var userMessage: String {
        switch self {
        case .helperNotInstalled:
            "管理员组件不可用，请在设置里重新安装"
        case .versionMismatch:
            "管理员组件版本过旧，组件需要更新"
        case .helperRejected(let reason):
            reason
        }
    }
}

/// App 侧 helper 客户端（`docs/01-ARCHITECTURE.md` §8：薄封装 + XPC 回调转 async）。
///
/// 只暴露与 `KernelHelperProtocol` 一一对应的四个方法；不拼命令、不传路径。
/// 连接建立失败 / 被 invalidate 一律映射成 `helperNotInstalled`，由上层给安装引导。
@MainActor
final class HelperClient {

    static let shared = HelperClient()

    private static let logger = Logger(subsystem: "com.clash.app", category: "helper")

    private var connection: NSXPCConnection?
    /// 连接是否被认为可用；`invalidationHandler` / `interruptionHandler` 会置回 false
    private(set) var isConnected = false

    // MARK: - 白名单方法

    /// helper 协议版本；不一致时由 `checkVersion()` 抛 `.versionMismatch`
    func ping() async throws -> Int {
        let raw: String = try await call { proxy, reply in proxy.ping(reply) }
        isConnected = true
        guard let actual = Int(raw) else {
            Self.logger.error("helper 返回无法解析的版本：\(raw, privacy: .public)")
            throw HelperClientError.versionMismatch(expected: HelperVersion, actual: nil)
        }
        return actual
    }

    /// App 启动 / 安装后调用：版本不齐直接抛错，触发「组件需要更新」
    func checkVersion() async throws {
        let actual = try await ping()
        guard actual == HelperVersion else {
            Self.logger.error("helper 版本不符 expected=\(HelperVersion) actual=\(actual)")
            throw HelperClientError.versionMismatch(expected: HelperVersion, actual: actual)
        }
    }

    /// 启动内核；返回 `pid=<n>`（helper 复用既有实例时也返回同一个）
    @discardableResult
    func startKernel() async throws -> String? {
        let result: (Bool, String?) = try await call { proxy, reply in
            proxy.startKernel { ok, message in reply((ok, message)) }
        }
        isConnected = true
        guard result.0 else {
            throw HelperClientError.helperRejected(reason: result.1 ?? "内核启动失败")
        }
        return result.1
    }

    func stopKernel() async throws {
        let stopped: Bool = try await call { proxy, reply in proxy.stopKernel(reply) }
        isConnected = true
        guard stopped else {
            throw HelperClientError.helperRejected(reason: "内核未能退出，请稍后重试")
        }
    }

    /// 运行中返回 pid 字符串，否则 nil
    func kernelState() async throws -> String? {
        let state: (Bool, String?) = try await call { proxy, reply in
            proxy.kernelState { running, pid in reply((running, pid)) }
        }
        isConnected = true
        return state.0 ? state.1 : nil
    }

    // MARK: - 连接

    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }

        let newConnection = NSXPCConnection(machServiceName: HelperLayout.machServiceName, options: [])
        newConnection.remoteObjectInterface = NSXPCInterface(with: KernelHelperProtocol.self)
        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                Self.logger.notice("helper 连接已失效")
                self?.teardown()
            }
        }
        newConnection.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in
                Self.logger.notice("helper 连接中断")
                self?.isConnected = false
            }
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    /// 丢弃旧连接：下次调用重新建连（helper 重启后能自愈）
    private func teardown() {
        isConnected = false
        connection?.invalidate()
        connection = nil
    }

    /// 把「代理 + 单个 reply」的回调式接口包成 async。
    ///
    /// 用 `ResumeOnce` 兜住「errorHandler 与 reply 都到达」的极端情况，避免
    /// `CheckedContinuation` 被 resume 两次而崩。
    private func call<T: Sendable>(
        _ body: (KernelHelperProtocol, @escaping (T) -> Void) -> Void
    ) async throws -> T {
        let connection = currentConnection()
        let once = ResumeOnce()

        return try await withCheckedThrowingContinuation { continuation in
            let proxyObject = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                Self.logger.error("helper XPC 调用失败：\(error.localizedDescription, privacy: .public)")
                Task { @MainActor [weak self] in self?.teardown() }
                guard once.claim() else { return }
                continuation.resume(throwing: HelperClientError.helperNotInstalled)
            }

            guard let proxy = proxyObject as? KernelHelperProtocol else {
                Self.logger.error("远程代理不符合 KernelHelperProtocol")
                Task { @MainActor [weak self] in self?.teardown() }
                if once.claim() {
                    continuation.resume(throwing: HelperClientError.helperNotInstalled)
                }
                return
            }

            body(proxy) { value in
                guard once.claim() else { return }
                continuation.resume(returning: value)
            }
        }
    }
}

/// 只允许第一个到达者生效（XPC 的回复与错误回调没有顺序保证）
private final class ResumeOnce: @unchecked Sendable {

    private let lock = NSLock()
    private var resumed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}
