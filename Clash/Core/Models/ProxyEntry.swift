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

    /// 测速三态：`history` 为空 = 从没测过，有条目但延迟 ≤ 0 = 超时
    var delayState: ProxyDelayState {
        guard let last = history?.last else { return .unknown }
        return last.delay > 0 ? .ok(last.delay) : .timeout
    }
}

/// 延迟历史的一条（`{"time": "...", "delay": 123}`）。
///
/// `time` 用于把「上次测速时间」一起写进延迟缓存；解析失败按缺失处理，
/// 不影响延迟本身（缓存侧会退回「本次拉取时间」）。
struct ProxyHistoryEntry: Decodable, Sendable, Equatable {
    let delay: Int
    let time: Date?

    private enum CodingKeys: String, CodingKey {
        case delay, time
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        delay = try container.decode(Int.self, forKey: .delay)
        if let text = try container.decodeIfPresent(String.self, forKey: .time) {
            time = Self.parse(text)
        } else {
            time = nil
        }
    }

    private static func parse(_ text: String) -> Date? {
        fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text)
    }

    /// 内核 `history[].time` 是 RFC3339（有的版本带毫秒，有的不带）
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter = ISO8601DateFormatter()
}
