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
/// 只暴露与 `KernelHelperProtocol` 一一对应的方法；不拼命令、不传路径。
/// 连接建立失败 / 被 invalidate 一律映射成 `helperNotInstalled`，由上层给安装引导。
@MainActor
final class HelperClient {

    static let shared = HelperClient()

    private static let logger = Logger(subsystem: "com.clash.app", category: "helper")

    private var connection: NSXPCConnection?

    // MARK: - 白名单方法

    /// helper 运行时快照：版本 + 内核二进制 / 运行配置 / 运行目录是否在位。
    ///
    /// 旧 helper（v2 安装版）只会回纯版本号，此时三个 `Bool?` 都是 nil（= 未知），
    /// 上层不做判断、交给 `startKernel` 报具体原因。
    func probe() async throws -> HelperRuntimeSnapshot {
        let raw: String = try await call { proxy, reply in proxy.ping(reply) }
        guard let snapshot = HelperRuntimeSnapshot(wireValue: raw) else {
            Self.logger.error("helper 返回无法解析的版本：\(raw, privacy: .public)")
            throw HelperClientError.versionMismatch(expected: HelperVersion, actual: nil)
        }
        return snapshot
    }

    /// App 启动 / 安装后调用：版本不齐直接抛错，触发「组件需要更新」
    @discardableResult
    func checkVersion() async throws -> HelperRuntimeSnapshot {
        let snapshot = try await probe()
        guard snapshot.version == HelperVersion else {
            Self.logger.error("helper 版本不符 expected=\(HelperVersion) actual=\(snapshot.version)")
            throw HelperClientError.versionMismatch(expected: HelperVersion, actual: snapshot.version)
        }
        return snapshot
    }

    /// 送运行配置正文（v2）：helper 校验后原子写 `runtime.yaml`，**不启动内核**。
    ///
    /// 正文超过 `HelperMaxRuntimeConfigBytes` 在本地就拒绝，不占用一次 XPC 往返
    /// （helper 侧同样会拒，双保险）。
    func applyRuntimeConfig(_ bytes: Data) async throws {
        guard !bytes.isEmpty else {
            throw HelperClientError.helperRejected(reason: "运行配置为空，无法写入")
        }
        guard bytes.count <= HelperMaxRuntimeConfigBytes else {
            throw HelperClientError.helperRejected(reason: "运行配置过大，已取消写入")
        }

        let result: (Bool, String?) = try await call { proxy, reply in
            proxy.applyRuntimeConfig(bytes) { ok, message in reply((ok, message)) }
        }
        guard result.0 else {
            throw HelperClientError.helperRejected(reason: result.1 ?? "运行配置写入失败")
        }
    }

    /// 启动内核；返回 `pid=<n>`（helper 复用既有实例时也返回同一个）
    @discardableResult
    func startKernel() async throws -> String? {        let result: (Bool, String?) = try await call { proxy, reply in
            proxy.startKernel { ok, message in reply((ok, message)) }
        }
        guard result.0 else {
            throw HelperClientError.helperRejected(reason: result.1 ?? "内核启动失败")
        }
        return result.1
    }

    func stopKernel() async throws {
        let stopped: Bool = try await call { proxy, reply in proxy.stopKernel(reply) }
        guard stopped else {
            throw HelperClientError.helperRejected(reason: "内核未能退出，请稍后重试")
        }
    }

    /// 运行中返回 pid 字符串，否则 nil
    func kernelState() async throws -> String? {
        let state: (Bool, String?) = try await call { proxy, reply in
            proxy.kernelState { running, pid in reply((running, pid)) }
        }
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
            }
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    /// 丢弃旧连接：下次调用重新建连（helper 重启后能自愈）
    private func teardown() {
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
            // XPC 的错误回调在私有队列上执行。闭包若继承 `@MainActor` 隔离，Swift 6 的
            // 执行器断言会在 Release 里也触发（`dispatch_assert_queue` → SIGTRAP）。
            // 2026-11-14 三次崩溃（组件安装/更新时 helper 被 bootout）都是这条路径，故显式
            // 标 `@Sendable` 让它脱离 actor 隔离，只有真正要碰 UI 状态时才 hop 回 MainActor。
            let proxyObject = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
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

            body(proxy) { @Sendable value in
                guard once.claim() else { return }
                continuation.resume(returning: value)
            }
        }
    }
}

// MARK: - 退出路径（同步）

/// 退出专用的一次性回复盒：`stopKernel` 的 reply 与 errorHandler 都可能到达。
private final class StopReply: @unchecked Sendable {

    private let lock = NSLock()
    private var stopped = false

    func set(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        stopped = value
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

extension HelperClient {

    /// 退出专用：**同步**等 `stopKernel` 回复，超时返回 `false`。
    ///
    /// 为什么单独建一条连接：`currentConnection()` 属于主 actor，退出流程要在主线程上阻塞
    /// 等待，复用那条连接会和「回调投递回主 actor」的转换层互相等待。这里用一次性连接 +
    /// 信号量，回复走 XPC 私有队列，不经过主线程。
    ///
    /// 超时**不代表没发出去**：请求已经投递给 helper，helper 会继续 SIGTERM → 3s → SIGKILL；
    /// 这里只是不再等确认（退出预算总共 3s，`AppTerminationGuard` 有硬超时）。
    nonisolated static func stopKernelSynchronously(timeout: TimeInterval = 1.5) -> Bool {
        let connection = NSXPCConnection(machServiceName: HelperLayout.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: KernelHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        let answer = StopReply()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            semaphore.signal()
        }) as? KernelHelperProtocol else {
            return false
        }

        proxy.stopKernel { stopped in
            answer.set(stopped)
            semaphore.signal()
        }

        return semaphore.wait(timeout: .now() + timeout) == .success && answer.value
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
