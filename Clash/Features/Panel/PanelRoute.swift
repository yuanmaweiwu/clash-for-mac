import Foundation

/// 面板内的导航目标（首层 / 节点列表 / 全部策略组 / 订阅管理）。
enum PanelRoute: Equatable, Sendable {
    case root
    case nodes(UUID)
    case allGroups
    case subscriptions
}
