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

    var id: String { name }

    /// 有效延迟（毫秒）；nil = 未测速或超时
    var delay: Int? { delayState.delay }

    var latencyText: String {
        switch delayState {
        case let .ok(delay): return "\(delay) ms"
        case .timeout: return "超时"
        case .unknown: return "—"
        }
    }
}
