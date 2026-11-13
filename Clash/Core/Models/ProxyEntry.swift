import Foundation

/// `GET /proxies` 里的一条（节点或策略组），是内核返回的原始形态。
///
/// 字典的键就是名字，`name` 字段不是所有版本都有，所以这里不声明 `name`。
struct ProxyEntry: Decodable, Sendable, Equatable {
    let type: String?
    /// 组当前选中的节点名（只有组有）
    let now: String?
    /// 组内条目（只有组有；这也是「是不是组」的判据）
    let all: [String]?
    let alive: Bool?
    let history: [ProxyHistoryEntry]?

    /// 带 `all` 的条目就是策略组
    var isGroup: Bool { all != nil }

    /// 最近一次延迟（毫秒）；0 / 缺失 = 未测速或超时
    var lastDelay: Int? {
        guard let delay = history?.last?.delay, delay > 0 else { return nil }
        return delay
    }
}

/// 延迟历史的一条（`{"time": "...", "delay": 123}`）
struct ProxyHistoryEntry: Decodable, Sendable, Equatable {
    let delay: Int
}
