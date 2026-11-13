// TODO(v0.2): 订阅服务接入后替换为真实模型
import Foundation

/// 订阅库里的一条（假数据）。
struct SubscriptionProfile: Identifiable, Sendable {
    let id = UUID()
    var name: String
    var source: SubscriptionSource
    var updatedText: String
    /// 三段缺一即省，不补占位（§4.8）
    var quotaText: String?
    var expiryText: String?
    var updateFailed: Bool
    /// 演示用：这条怎么更新都失败
    var alwaysFailsUpdate = false

    /// 第二行：更新时间 · 用量（到期信息单独放在行尾）
    var detailText: String {
        var parts = [updatedText]
        if let quotaText, !quotaText.isEmpty { parts.append(quotaText) }
        if updateFailed { parts.append("更新失败，仍在使用旧配置") }
        return parts.joined(separator: " · ")
    }
}
