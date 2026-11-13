import Foundation

/// 一张策略组卡（`GET /proxies` 里带 `all` 的组）；顺序与排序规则见 `docs/02-UI-SPEC.md` §3.4 / §4.7。
struct ProxyGroupModel: Identifiable, Sendable, Equatable {
    /// 内核里的组名，直接当 id
    let name: String
    /// `Selector` / `URLTest` / `Fallback` / `LoadBalance` / `Relay` …
    let type: String
    /// 当前选中节点（组内嵌套组时是子组名）
    var now: String?
    /// 按内核配置顺序（`all` 的原顺序）
    var nodes: [ProxyNodeModel]
    /// 组自身最近一次延迟；nil = 未测速 / 超时
    var delay: Int?
    /// 是否 pin 到首屏（UI 偏好，进内存，后续落 `profiles/index.json`）
    var isPinned: Bool
    /// 星标是否可点：主组（默认常驻）与 `GLOBAL` 都不可点
    var canPin: Bool
    /// `GLOBAL`：只在「全部策略组」二级页出现，不进首屏
    let isGlobal: Bool

    var id: String { name }

    var selectedNode: ProxyNodeModel? { nodes.first { $0.name == now } }

    /// 按延迟升序；超时/未测速沉底；同延迟按配置顺序（稳定排序）
    var nodesSortedByLatency: [ProxyNodeModel] {
        nodes.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.delay ?? Int.max
                let right = rhs.element.delay ?? Int.max
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 卡内只露 3 行：选中项恒第一，其余按延迟升序取前 2（超时自然沉底）
    var orderedNodes: [ProxyNodeModel] {
        guard let selected = selectedNode else { return Array(nodesSortedByLatency.prefix(3)) }
        let rest = nodesSortedByLatency.filter { $0.name != selected.name }
        return [selected] + rest.prefix(2)
    }

    /// 排序键：变化时整组交叉淡入，不整列跳动
    var cardOrderKey: String { orderedNodes.map(\.name).joined(separator: ",") }
    var listOrderKey: String { nodesSortedByLatency.map(\.name).joined(separator: ",") }

    var extraCount: Int { max(nodes.count - 3, 0) }

    func isSelected(_ node: ProxyNodeModel) -> Bool { node.name == now }
}
