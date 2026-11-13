import Foundation

/// 分组卡里的一个节点（假数据）。
struct DemoNode: Identifiable, Sendable {
    let id = UUID()
    let name: String
    /// nil 表示超时 / 不可用
    let latency: Int?

    var latencyText: String {
        guard let latency else { return "超时" }
        return "\(latency) ms"
    }
}
