import Foundation

/// 当前机器对应的内核资产（`adr/0001` 补充：允许 x86_64）。
///
/// 上游按 `darwin-<arch>` 发布两份互不通用的二进制：`arm64` / `amd64`。
/// 校验值也必须按架构分开（`Resources/Kernel/SHA256-<arch>`），
/// 否则 Intel 机器会拿 arm64 的哈希去校验 amd64 的字节，永远失败。
enum KernelAsset {
    #if arch(x86_64)
    /// 上游资产名里的架构后缀（注意不是 `x86_64`）
    static let suffix = "amd64"
    /// 面向用户的架构名（与 `uname -m` 一致）
    static let archLabel = "x86_64"
    #else
    static let suffix = "arm64"
    static let archLabel = "arm64"
    #endif

    /// 包内校验文件名
    static var checksumFileName: String { "SHA256-\(suffix)" }

    /// 校验失败文案里必须点明「当前架构 + 校验的是哪份资产」
    static var checksumNote: String {
        "当前机器架构 \(archLabel)，校验的是 \(suffix) 资产"
    }
}

/// 内核下载 / 校验失败的原因（`adr/0012`）。
///
/// 分类必须能对上用户能采取的动作：网络不通（换网络 / 填镜像）、校验失败（重试）、
/// 磁盘写不进去（清空间 / 查权限）。**不允许**静默回退到「那就没有内核」。
enum KernelProvisionError: Error, Equatable, Sendable {
    /// 包内缺 `Resources/Kernel/VERSION` 或 `SHA256`（构建期漏拷）
    case metadataMissing(String)
    /// 传输层失败：断网 / DNS / 超时 / 镜像不可达；参数只进日志
    case network(String)
    /// HTTP 非 2xx（镜像返回 404 / 403 等）
    case httpStatus(Int)
    /// 解压后的 sha256 与 committed 的 `SHA256` 不一致
    case checksumMismatch(expected: String, actual: String)
    /// 磁盘写入 / 移动失败
    case disk(String)
    /// `gunzip` 失败
    case decompressFailed(String)
    /// 自动模式下所有源都不可达（有一个成功就不会走到这里）
    case allSourcesUnreachable
    /// 另一个下载任务迟迟不结束（等锁超时）
    case busy
    /// 等待期间任务被取消
    case cancelled
    /// 检查更新失败：GitHub API 不可达 / 返回的不是 release JSON
    case updateCheck(String)
    /// 升级下载到的二进制 `-v` 输出不含目标 tag（或根本跑不起来）
    case kernelVersionMismatch(String)

    /// 面向用户的一句话（banner / 提示）
    var userMessage: String {
        switch self {
        case .metadataMissing:
            "安装包缺少内核版本信息，请重新安装应用"
        case .network:
            "内核下载失败：网络不可达，请检查网络，或在设置里填写下载镜像后重试"
        case .httpStatus(let code):
            "内核下载失败：服务器返回 \(code)，可稍后重试或更换下载镜像"
        case .checksumMismatch:
            "内核校验失败：\(KernelAsset.checksumNote)，内容与预期不一致，已删除，请重试"
        case .disk:
            "内核写入失败：磁盘空间不足或目录不可写，请检查后重试"
        case .decompressFailed:
            "内核解压失败，请重试（或更换下载源）"
        case .allSourcesUnreachable:
            "所有下载源均不可达，可在设置里换镜像后重试"
        case .busy:
            "另一个内核下载任务尚未结束，请稍后重试"
        case .cancelled:
            "内核下载已取消"
        case .updateCheck:
            "检查更新失败：GitHub 不可达，可换下载镜像后重试"
        case .kernelVersionMismatch:
            "更新失败：下载的内核版本不符或无法执行，已保留原内核"
        }
    }

    /// 只进日志的细节（不含订阅 / secret）
    var logDescription: String {
        switch self {
        case .metadataMissing(let name): "metadataMissing（缺 \(name)）"
        case .network(let detail): "network（\(detail)）"
        case .httpStatus(let code): "httpStatus（\(code)）"
        case .checksumMismatch(let expected, let actual):
            "checksumMismatch（expected=\(expected) actual=\(actual)）"
        case .disk(let detail): "disk（\(detail)）"
        case .decompressFailed(let detail): "decompressFailed（\(detail)）"
        case .allSourcesUnreachable: "allSourcesUnreachable（所有下载源失败）"
        case .busy: "busy（等待其他下载任务超时）"
        case .cancelled: "cancelled（任务取消）"
        case .updateCheck(let detail): "updateCheck（\(detail)）"
        case .kernelVersionMismatch(let detail): "kernelVersionMismatch（\(detail)）"
        }
    }
}
