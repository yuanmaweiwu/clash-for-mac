/// TUN 磁贴的状态（§4.2 五态 + 两个过渡态 + 启动失败）。
///
/// §4.2 的五态是：已关闭 / 需要授权 / 等待授权 / 已开启 / 授权失败；
/// `starting` / `stopping` 是两个过渡态（与连接磁贴的「正在启动 / 正在停止」同构），
/// `startFailed` 区分「不是授权问题、而是内核起不来」——此时文案不能写「授权失败」。
///
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
        case .off: "已关闭"
        case .requiresAuth: "需要授权"
        case .waitingAuth: "等待授权"
        case .starting: "正在启动"
        case .on: "已开启"
        case .stopping: "正在停止"
        case .authFailed: "授权失败"
        case .startFailed: "开启失败"
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
        case .off: "按下开启 TUN"
        case .requiresAuth: "按下查看管理员组件安装说明"
        case .waitingAuth: "正在等待管理员授权"
        case .starting: "正在启动 TUN"
        case .on: "按下关闭 TUN"
        case .stopping: "正在停止 TUN"
        case .authFailed, .startFailed: "按下重试"
        }
    }
}
