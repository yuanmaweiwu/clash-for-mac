import Foundation

/// 节点的测速状态。
///
/// `unknown` 与 `timeout` 的延迟都是「没有数字」，但含义相反：
/// 从没测过不能诬陷成「超时」，用户会以为节点坏了。UI 与排序都按这个三态走。
enum ProxyDelayState: Sendable, Equatable, Hashable {
    /// `history` 为空：从没测过
    case unknown
    /// 测到了有效延迟（毫秒）
    case ok(Int)
    /// 测过但失败：内核返回 0 或负数
    case timeout

    /// 有效延迟；`unknown` / `timeout` 都是 nil
    var delay: Int? {
        if case let .ok(value) = self { return value }
        return nil
    }
}

/// 策略组里的一个条目（来自 `GET /proxies`）。
struct ProxyNodeModel: Identifiable, Sendable, Equatable {
    /// 内核里的名字，全局唯一，直接当 id
    let name: String
    let type: String
    /// 该条目本身是策略组（组内嵌套组）：选中它 = 让父组指向这个子组
    let isGroup: Bool
    /// 测速三态（未测速 / 正常 / 超时）
    var delayState: ProxyDelayState
    /// 内核 `alive`；拿不到时按可用处理（否则整组都点不动）
    var isAvailable: Bool
    /// 延迟来自本地缓存（内核本次启动没带 `history`）：显示加 `~`，不当作新鲜值染色
    var isStale: Bool = false
    /// 该延迟的测速时间（新鲜值与缓存值都有；只有缓存值会展示成「上次测速」）
    var lastTestedAt: Date? = nil

    var id: String { name }

    /// 有效延迟（毫秒）；nil = 未测速或超时
    var delay: Int? { delayState.delay }

    var latencyText: String {
        switch delayState {
        case let .ok(delay): return isStale ? "~\(delay) ms" : "\(delay) ms"
        case .timeout: return "超时"
        case .unknown: return "—"
        }
    }

    /// hover 提示：陈旧值告诉用户这是多久以前的测速结果
    var staleHint: String? {
        guard isStale else { return nil }
        guard let lastTestedAt else { return "上次测速：时间未知" }

        let minutes = Int(max(0, Date().timeIntervalSince(lastTestedAt)) / 60)
        if minutes < 1 { return "上次测速：刚刚" }
        if minutes < 60 { return "上次测速：\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "上次测速：\(hours) 小时前" }
        return "上次测速：\(hours / 24) 天前"
    }
}
