#if DEBUG
import Foundation

/// XPC 错误路径自检（仅 DEBUG）：`CLASH_XPC_ERR_HARNESS=1`。
///
/// 复跑 `9d3c16d` 修的那条崩溃：`HelperClient.call` 的 errorHandler 在 XPC 私有队列执行，
/// 闭包若继承 `@MainActor`，Swift 6 执行器断言会 `SIGTRAP`（`EXC_BREAKPOINT`）。
/// 生产触发条件是「组件安装 / 更新时 helper 被 bootout」，要密码、代价高；这里改用
/// **不存在的 mach service** 注入同一条错误回调路径：`remoteObjectProxyWithErrorHandler`
/// 会立刻失败并调用 errorHandler。
///
/// 断言：1s 内收到 `HelperClientError.helperNotInstalled`，进程不崩。
@MainActor
enum XPCErrorHarness {

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["CLASH_XPC_ERR_HARNESS"] == "1"
    }

    /// 返回 `true` 表示夹具已接手启动流程（调用方不要再建 UI）。
    static func runIfRequested() -> Bool {
        guard isRequested else { return false }
        Task { @MainActor in await run() }
        return true
    }

    private static func run() async {
        let serviceName = "com.clash.helper.nonexistent"
        let client = HelperClient(serviceName: serviceName)
        print("XPC-ERR 连接不存在的 mach service：\(serviceName)")
        print("XPC-ERR pid=\(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)

        let began = Date()
        let outcome = await withTimeout(seconds: 1) {
            try await client.kernelState()
        }
        let elapsed = Date().timeIntervalSince(began)

        switch outcome {
        case .value(let pid):
            print("FAIL xpc-error 未收到错误（pid=\(pid ?? "nil")），夹具未触发错误回调")
            exit(1)
        case .timeout:
            print("FAIL xpc-error 1s 内未返回（错误回调没被调用）")
            exit(1)
        case .failure(let error):
            guard let helperError = error as? HelperClientError, helperError == .helperNotInstalled else {
                print("FAIL xpc-error 错误类型不符：\(error)")
                exit(1)
            }
            guard elapsed < 1 else {
                print("FAIL xpc-error 返回过慢：\(Int(elapsed * 1000))ms")
                exit(1)
            }
            print(String(
                format: "PASS xpc-error-no-crash %.0fms error=helperNotInstalled",
                elapsed * 1000
            ))
            fflush(stdout)
            exit(0)
        }
    }

    // MARK: - 超时

    private enum Outcome {
        case value(String?)
        case failure(any Error)
        case timeout
    }

    /// 超时只用于判定；真正要观察的是「错误回调在私有队列执行时会不会崩」。
    private static func withTimeout(
        seconds: TimeInterval,
        _ operation: @escaping @MainActor () async throws -> String?
    ) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let once = ClaimOnce()

            Task { @MainActor in
                do {
                    let value = try await operation()
                    if once.claim() { continuation.resume(returning: .value(value)) }
                } catch {
                    if once.claim() { continuation.resume(returning: .failure(error)) }
                }
            }

            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { continuation.resume(returning: .timeout) }
            }
        }
    }

    /// 继续体（reply / 超时）只允许第一个到达者生效。
    private final class ClaimOnce: @unchecked Sendable {
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
}
#endif
