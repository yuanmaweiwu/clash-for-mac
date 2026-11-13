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

    /// 按延迟升序；超时/未测速沉底；同延迟按配置顺序（稳定排序）
    var nodesSortedByLatency: [DemoNode] {
        nodes.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.latency ?? Int.max
                let right = rhs.element.latency ?? Int.max
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 卡内只露 3 行：选中项恒第一，其余按延迟升序取前 2（超时自然沉底）
    var orderedNodes: [DemoNode] {
        guard let selected = selectedNode else { return Array(nodesSortedByLatency.prefix(3)) }
        let rest = nodesSortedByLatency.filter { $0.id != selected.id }
        return [selected] + rest.prefix(2)
    }

    /// 排序键：变化时整组交叉淡入，不整列跳动
    var cardOrderKey: String { orderedNodes.map(\.id.uuidString).joined(separator: ",") }
    var listOrderKey: String { nodesSortedByLatency.map(\.id.uuidString).joined(separator: ",") }

    var extraCount: Int { max(nodes.count - 3, 0) }

    var selectedNode: DemoNode? { nodes.first { $0.id == selectedNodeID } }

    func isSelected(_ node: DemoNode) -> Bool { node.id == selectedNodeID }
}
