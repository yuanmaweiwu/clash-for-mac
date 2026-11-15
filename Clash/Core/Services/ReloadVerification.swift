import Foundation
import OSLog

/// 热重载成功的判据：`/version` 可达 + `/proxies` 已经换成本次配置声明的组 / 节点。
///
/// 为什么不用「和改前比有没有变化」：更新同一条订阅时组名 / 节点数可能完全一样，
/// 那只会在正确重载后误判失败。这里对齐的是**本次配置本身**：
/// - 策略组名集合必须精确匹配（旧订阅的组必须消失，内核合成的 `GLOBAL` 除外）
/// - 配置里声明的节点名必须全部出现在 `/proxies`（节点数量增减也能看出来）
struct ReloadExpectation: Sendable, Equatable {

    /// 本次配置声明的策略组名（不含 `GLOBAL`）
    let groupNames: Set<String>
    /// 本次配置声明的节点名
    let proxyNames: Set<String>

    func isSatisfied(by proxies: [String: ProxyEntry]) -> Bool {
        let observedGroups = Set(proxies.filter { $0.value.isGroup }.keys)
            .subtracting(["GLOBAL"])
        guard observedGroups == groupNames else { return false }
        return proxyNames.isSubset(of: Set(proxies.keys))
    }
}

/// 轮询校验 `PUT /configs` 是否真的生效（最多 10s，150ms 一轮）。
enum ReloadVerifier {

    private static let logger = Logger(subsystem: "com.clash.app", category: "kernel")

    /// 验证窗口：超过即判定失败，调用方回退 stop→start / disable+enable
    static let verificationTimeout: Duration = .seconds(10)
    private static let pollInterval: Duration = .milliseconds(150)

    static func wait(
        client: ClashAPIClient,
        expectation: ReloadExpectation,
        timeout: Duration = verificationTimeout
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        var lastReason = "尚未拿到 /proxies"

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                _ = try await client.version(timeout: 1)
                let proxies = try await client.proxies()
                if expectation.isSatisfied(by: proxies) {
                    return
                }
                let observed = Set(proxies.filter { $0.value.isGroup }.keys)
                    .subtracting(["GLOBAL"])
                lastReason = "组名不匹配（期望 \(expectation.groupNames.count) 个，实际 \(observed.count) 个）"
            } catch {
                lastReason = "API 不可达（\(String(describing: error))）"
            }
            try await Task.sleep(for: pollInterval)
        }

        logger.error("热重载验证超时：\(lastReason, privacy: .public)")
        throw HotReloadError.verificationTimedOut(lastReason)
    }
}
