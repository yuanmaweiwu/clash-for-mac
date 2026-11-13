// TODO(v0.2): 替换为真实模型，当前为面板假数据
import Foundation

/// 面板状态条的六种演示状态（对齐 `docs/02-UI-SPEC.md` §3.3）。
///
/// 六种都会出现：`proxying` 需要「内核 running + 系统代理读回校验通过」，
/// `direct` 由代理模式算出来。`showsLiveTraffic` 仍为 false（`/traffic` 未接），
/// 所以速率位显示 `—`。
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
