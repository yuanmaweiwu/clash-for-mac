import Foundation

/// 面板内的导航目标（首层 / 节点列表 / 全部策略组 / 订阅管理 / 添加订阅 / 连接列表 / 设置）。
///
/// 设置与添加订阅也是这里的二级页：只有日志这类才开独立窗口（`docs/02-UI-SPEC.md` §4.9 / §4.10）。
enum PanelRoute: Equatable, Sendable {
    case root
    case nodes(String)
    case allGroups
    case subscriptions
    /// 添加订阅（由订阅页 `＋` 推入）
    case subscriptionNew
    case connections
    /// 设置（由底栏 ⚙ 或 ⌘, 推入）
    case settings
}
