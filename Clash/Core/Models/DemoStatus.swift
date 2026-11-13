// TODO(v0.2): 替换为真实模型，当前为面板假数据
import Foundation

/// 面板状态条的五种状态（对齐 `docs/02-UI-SPEC.md` §3.3）。
///
/// 状态只由「内核相位 + 是否接管系统代理」决定；代理模式（规则/全局/直连）
/// 不再影响状态条文案。`proxying` = 内核 running + 系统代理读回校验通过。
/// 速率位另看 `/traffic` WS 是否在线（`showsLiveTraffic`），与系统代理开关无关。
enum DemoStatus: String, CaseIterable, Identifiable, Sendable {
    case idle
    case starting
    case ready
    case proxying
    case failed

    var id: String { rawValue }

    /// 状态条文案
    var title: String {
        switch self {
        case .idle: "未运行"
        case .starting: "启动中"
        case .ready: "已就绪"
        case .proxying: "代理中"
        case .failed: "启动失败"
        }
    }

    /// 有实时速率的状态
    var hasLiveRates: Bool {
        switch self {
        case .ready, .proxying: true
        case .idle, .starting, .failed: false
        }
    }
}
