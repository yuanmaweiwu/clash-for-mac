import Foundation

/// 系统代理磁贴的五态（`docs/02-UI-SPEC.md` §4.2）。
///
/// 磁贴语义 = **系统代理总开关**（不是内核启停）：
/// 未启用 → 点一下 = 内核没跑先启动，再接管系统代理；
/// 已启用 → 点一下 = 只还原系统代理（内核继续运行，节点仍可见可选）。
///
/// 与 TUN 磁贴共用「启用 / 未启用」词根：两者是替代关系（互斥），
/// 文案上不能出现「启动」这种像在说内核的词。
enum ConnectionState: Equatable, Sendable {
    case off
    case turningOn
    case on
    case turningOff
    /// 失败分方向：启用失败与停用失败的可操作提示不同
    case failed(Stage)

    enum Stage: Equatable, Sendable {
        case enable
        case disable
    }

    /// 过渡中：磁贴禁用点击
    var isBusy: Bool {
        self == .turningOn || self == .turningOff
    }

    /// 副标题（磁贴五态文案，§4.2）
    var subtitle: String {
        switch self {
        case .off: "未启用"
        case .turningOn: "正在启用"
        case .on: "已启用"
        case .turningOff: "正在停用"
        case .failed(.enable): "启用失败"
        case .failed(.disable): "停用失败"
        }
    }

    /// 可访问性提示（§4.2：随态切换）
    var hint: String {
        switch self {
        case .off: "按下启用系统代理"
        case .turningOn, .turningOff: "正在切换，请稍候"
        case .on: "按下停用系统代理"
        case .failed(.enable): "按下重试启用系统代理"
        case .failed(.disable): "按下重试停用系统代理"
        }
    }
}
