import Foundation

/// 内核错误分类（`core-process` 技能 §7）。
///
/// 前 7 类是技能里约定的用户可区分类别；`geodataUnavailable` 与 `startTimeout`
/// 是 v0.1 实机跑起来后必须单独区分的情形（首次联网准备地理数据 / 就绪超时）。
enum KernelError: Error, Equatable, Sendable {
    /// 包内无 mihomo 或不可执行
    case binaryMissing
    /// 签名校验失败（v0.1 无签名身份，占位）
    case binaryRejected
    /// `mihomo -t` 退出码非 0
    case configInvalid(detail: String)
    /// 端口绑定失败
    case portInUse
    /// helper 未安装（v0.1 不应出现）
    case helperNotInstalled
    /// 授权被拒
    case permissionDenied
    /// 非预期退出
    case crashed(code: Int32)
    /// 首次启动需要联网下载 geoip.metadb / geosite
    case geodataUnavailable
    /// 启动后在超时内 `/version` 未就绪
    case startTimeout

    /// 面向用户的一句话（banner / 提示）
    var userMessage: String {
        switch self {
        case .binaryMissing:
            "内核文件缺失，请重新安装应用"
        case .binaryRejected:
            "内核签名校验未通过，请重新安装应用"
        case .configInvalid:
            "配置无效，请检查或更换配置"
        case .portInUse:
            "端口被占用，请稍后重试或更换端口"
        case .helperNotInstalled:
            "需要管理员组件（当前版本尚未接入）"
        case .permissionDenied:
            "权限被拒绝，请到「系统设置 → 通用 → 登录项与扩展」允许"
        case .crashed(let code):
            "内核异常退出（退出码 \(code)），点此查看日志"
        case .geodataUnavailable:
            "首次启动需要联网准备地理数据，请检查网络后重试"
        case .startTimeout:
            "内核启动超时，请重试或查看日志"
        }
    }

    /// 只进日志的细节（不含 secret）
    var logDescription: String {
        switch self {
        case .binaryMissing: "binaryMissing（包内 mihomo 不存在或不可执行）"
        case .binaryRejected: "binaryRejected（签名校验失败）"
        case .configInvalid(let detail): "configInvalid（\(detail)）"
        case .portInUse: "portInUse（端口绑定失败）"
        case .helperNotInstalled: "helperNotInstalled（helper 未安装）"
        case .permissionDenied: "permissionDenied（授权被拒）"
        case .crashed(let code): "crashed（exit code \(code)）"
        case .geodataUnavailable: "geodataUnavailable（geoip.metadb 缺失且无法下载）"
        case .startTimeout: "startTimeout（就绪探测超时）"
        }
    }
}
