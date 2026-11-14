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
    /// 是否可切换固定状态：主组（默认常驻）与 `GLOBAL` 都不可切换
    var canPin: Bool
    /// `GLOBAL`：只在「全部策略组」二级页出现，不进首屏
    let isGlobal: Bool

    var id: String { name }

    var selectedNode: ProxyNodeModel? { nodes.first { $0.name == now } }

    /// 新鲜测速按延迟升序 → 缓存值 → 未测速 → 超时；同类按配置顺序（稳定排序）
    var nodesSortedByLatency: [ProxyNodeModel] {
        nodes.enumerated()
            .sorted { lhs, rhs in
                let left = Self.sortKey(lhs.element)
                let right = Self.sortKey(rhs.element)
                if left.rank != right.rank { return left.rank < right.rank }
                if left.delay != right.delay { return left.delay < right.delay }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 排序键：新鲜 `ok`（0 + 延迟）→ 缓存 `ok`（1 + 延迟）→ `unknown`（2）→ `timeout`（3）
    ///
    /// 缓存值排在新鲜值之后：它仍有参考价值，但不能压过刚测过的真实延迟。
    private static func sortKey(_ node: ProxyNodeModel) -> (rank: Int, delay: Int) {
        switch node.delayState {
        case let .ok(delay): return (node.isStale ? 1 : 0, delay)
        case .unknown: return (2, 0)
        case .timeout: return (3, 0)
        }
    }

    /// 卡内只露 3 行：选中项恒第一，其余按延迟升序取前 2（未测速 / 超时自然沉底）
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
