import Foundation

/// 面板状态条的六种演示状态（对齐 `docs/02-UI-SPEC.md` §3.3）。
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

    /// 连接磁贴是否为「开」
    var isConnected: Bool {
        switch self {
        case .proxying, .direct: true
        case .idle, .starting, .ready, .failed: false
        }
    }
}
