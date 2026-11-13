// TODO(v0.2): 订阅服务接入后替换为真实模型
import Foundation

/// 订阅来源（只影响行首图标）。
enum SubscriptionSource: String, Sendable {
    case url
    case local
}
