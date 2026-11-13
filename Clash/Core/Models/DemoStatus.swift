// TODO(v0.2): 替换为真实模型，当前为面板假数据
import Foundation

/// 面板状态条的六种演示状态（对齐 `docs/02-UI-SPEC.md` §3.3）。
///
/// v0.1 只会出现 `idle` / `starting` / `ready` / `failed`（ADR-0007：无系统代理）；
/// `proxying` / `direct` 要等 v0.2 接管流量后才会被算出来。
enum DemoStatus: String, CaseIterable, Identifiable, Sendable {
    case idle
    case starting
    case ready
    case proxying
    case direct
    case failed

    var id: String { rawValue }

    /// 状态条文案
    var title: String {
        switch self {
        case .idle: "未运行"
        case .starting: "启动中"
        case .ready: "已就绪"
        case .proxying: "代理中"
        case .direct: "直连"
        case .failed: "启动失败"
        }
    }

    /// 有实时速率的状态
    var hasLiveRates: Bool {
        switch self {
        case .ready, .proxying, .direct: true
        case .idle, .starting, .failed: false
        }
    }
}
