// TODO(v0.2): 替换为真实模型，当前为面板假数据
import Foundation

/// 分组卡里的一个节点（假数据）。
struct DemoNode: Identifiable, Sendable {
    let id = UUID()
    let name: String
    /// nil 表示超时 / 不可用
    var latency: Int?

    var latencyText: String {
        guard let latency else { return "超时" }
        return "\(latency) ms"
    }
}
