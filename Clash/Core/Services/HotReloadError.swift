import Foundation

/// 配置热重载（`PUT /configs?force=true`）的失败原因。
///
/// 这些错误不会直接进 banner：调用方（`SubscriptionActions`）一律回退原来的
/// stop→start / disable+enable，只有回退也失败时用户才会看到原有错误文案。
/// 这里保留可读原因，供日志定位「为什么不走热重载」。
enum HotReloadError: Error, Equatable, Sendable {
    /// 内核不在 running / 正在过渡，没有可复用的端点
    case notRunning
    /// 缺少重建 runtime 必需的端点或配置（dns 端口 / active profile）
    case missingEndpoint
    /// 热重载后 root 内核 pid 变了：说明进程被替换，不是就地重载
    case kernelRestarted(before: String?, after: String?)
    /// 热重载后 utun 接口集合变了：说明 TUN 被重建
    case tunnelChanged
    /// 10s 内 `/version` 或 `/proxies` 未达到期望（参数是最后一轮诊断）
    case verificationTimedOut(String)

    var logDescription: String {
        switch self {
        case .notRunning:
            "notRunning（内核不在可热重载状态）"
        case .missingEndpoint:
            "missingEndpoint（缺少 controller / dns 端口或 active 配置）"
        case .kernelRestarted(let before, let after):
            "kernelRestarted（pid \(before ?? "nil") → \(after ?? "nil")）"
        case .tunnelChanged:
            "tunnelChanged（utun 接口集合变化）"
        case .verificationTimedOut(let reason):
            "verificationTimedOut（\(reason)）"
        }
    }
}
