/// TUN 磁贴的状态（§4.2 五态 + 两个过渡态 + 启用失败）。
///
/// §4.2 的五态是：未启用 / 需要授权 / 等待授权 / 已启用 / 授权失败；
/// `starting` / `stopping` 是两个过渡态（与系统代理磁贴的「正在启用 / 正在停用」同构），
/// `startFailed` 区分「不是授权问题、而是内核起不来」——此时文案不能写「授权失败」。
///
/// 与系统代理磁贴共用「启用 / 未启用」词根：两者互斥，任选其一。
/// 与 `TunService.Phase` 一一映射，见 `TunService.tileState`。
enum TunState: String, Sendable {
    case off
    case requiresAuth
    case waitingAuth
    case starting
    case on
    case stopping
    case authFailed
    case startFailed

    /// 磁贴副标题（§4.2 五态 + 过渡）
    var subtitle: String {
        switch self {
        case .off: "未启用"
        case .requiresAuth: "需要授权"
        case .waitingAuth: "等待授权"
        case .starting: "正在启用"
        case .on: "已启用"
        case .stopping: "正在停用"
        case .authFailed: "授权失败"
        case .startFailed: "启用失败"
        }
    }

    /// 是否处于过渡 / 等待态（图标座换转圈）
    var isProgressing: Bool {
        switch self {
        case .waitingAuth, .starting, .stopping: true
        case .off, .requiresAuth, .on, .authFailed, .startFailed: false
        }
    }

    var accessibilityHint: String {
        switch self {
        case .off: "按下启用 TUN 模式"
        case .requiresAuth: "按下查看管理员组件安装说明"
        case .waitingAuth: "正在等待管理员授权"
        case .starting: "正在启用 TUN 模式"
        case .on: "按下停用 TUN 模式"
        case .stopping: "正在停用 TUN 模式"
        case .authFailed, .startFailed: "按下重试"
        }
    }
}
