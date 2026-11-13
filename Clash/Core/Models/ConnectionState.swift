import Foundation

/// 连接磁贴的五态（`docs/02-UI-SPEC.md` §4.2）。
///
/// 磁贴语义 = **系统代理总开关**（不再是内核启停）：
/// 关闭 → 点一下 = 起内核 + 接管系统代理；开启 → 点一下 = 还原系统代理（v0.2 同时停内核）。
enum ConnectionState: Equatable, Sendable {
    case off
    case turningOn
    case on
    case turningOff
    /// 失败分方向：开启失败与关闭失败的可操作提示不同
    case failed(Stage)

    enum Stage: Equatable, Sendable {
        case enable
        case disable
    }

    /// 过渡中：磁贴禁用点击
    var isBusy: Bool {
        self == .turningOn || self == .turningOff
    }

    /// 副标题（磁贴四态文案，§4.2）
    var subtitle: String {
        switch self {
        case .off: "已关闭"
        case .turningOn: "正在启动"
        case .on: "已开启"
        case .turningOff: "正在关闭"
        case .failed(.enable): "启动失败"
        case .failed(.disable): "关闭失败"
        }
    }

    /// 可访问性提示（§4.2：随态切换）
    var hint: String {
        switch self {
        case .off: "按下开启代理"
        case .turningOn, .turningOff: "正在切换，请稍候"
        case .on: "按下关闭代理"
        case .failed(.enable): "按下重试开启代理"
        case .failed(.disable): "按下重试关闭代理"
        }
    }
}
