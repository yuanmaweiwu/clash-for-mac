import Foundation

/// 一张策略组卡：卡头 32 + 三行 32 = 128pt；二级面板里列出全部节点（§3.4）。
struct DemoGroup: Identifiable, Sendable {
    let id = UUID()
    let name: String
    var nodes: [DemoNode]
    var selectedNodeID: UUID?
    /// 主组（节点选择）：固定显示，不可取消 pin
    let isMainGroup: Bool
    /// 是否固定到首屏
    var isPinned: Bool

    init(name: String, nodes: [DemoNode], isMainGroup: Bool = false, isPinned: Bool = false) {
        self.name = name
        self.nodes = nodes
        self.isMainGroup = isMainGroup
        self.isPinned = isPinned || isMainGroup
        self.selectedNodeID = nodes.first?.id
    }

    /// 卡内只露 3 行，其余走「还有 N 个 ›」
    var visibleNodes: [DemoNode] { Array(nodes.prefix(3)) }

    var extraCount: Int { max(nodes.count - 3, 0) }

    var selectedNode: DemoNode? { nodes.first { $0.id == selectedNodeID } }

    func isSelected(_ node: DemoNode) -> Bool { node.id == selectedNodeID }
}
