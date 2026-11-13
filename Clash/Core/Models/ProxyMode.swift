// TODO(v0.2): 替换为真实模型，当前为面板假数据
import Foundation

/// 代理模式分段（§4.3）
enum ProxyMode: String, CaseIterable, Identifiable, Sendable {
    case rule
    case global
    case direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rule: "规则"
        case .global: "全局"
        case .direct: "直连"
        }
    }
}
