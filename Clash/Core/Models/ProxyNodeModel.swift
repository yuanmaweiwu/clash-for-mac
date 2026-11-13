import Foundation

/// 策略组里的一个条目（来自 `GET /proxies`）。
struct ProxyNodeModel: Identifiable, Sendable, Equatable {
    /// 内核里的名字，全局唯一，直接当 id
    let name: String
    let type: String
    /// 该条目本身是策略组（组内嵌套组）：选中它 = 让父组指向这个子组
    let isGroup: Bool
    /// nil 表示超时 / 未测速
    var delay: Int?
    /// 内核 `alive`；拿不到时按可用处理（否则整组都点不动）
    var isAvailable: Bool

    var id: String { name }

    var latencyText: String {
        guard let delay else { return "超时" }
        return "\(delay) ms"
    }
}
