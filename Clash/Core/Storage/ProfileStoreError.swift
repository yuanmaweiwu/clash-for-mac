import Foundation

/// 订阅库的错误分类（`core-process` §7 的订阅部分）。
///
/// 面向用户一律用 `userMessage`，技术细节只进日志：订阅 URL 里常带 token。
enum ProfileStoreError: Error, Equatable, Sendable {
    /// 链接不是合法的 http(s) URL
    case invalidURL
    /// 索引里没有这个 id
    case notFound
    /// 本地来源的源文件已被删除
    case sourceMissing
    /// 读本地文件失败
    case fileUnreadable
    /// 内容不是 YAML / 顶层不是映射
    case notYAML
    /// 422 / 403 或返回非 YAML：该订阅不认本客户端（ADR-0006）
    case unsupportedFormat
    /// 传输层失败（超时 / 断网 / DNS）
    case network
    /// 包内没有可执行的 mihomo
    case binaryMissing
    /// `mihomo -t` 不通过；`detail` 只进日志
    case configInvalid(detail: String)
    /// 重命名为空
    case emptyName
    /// 写本地文件失败（磁盘满 / 权限）
    case storageFailure

    var userMessage: String {
        switch self {
        case .invalidURL:
            "订阅链接无效"
        case .notFound:
            "订阅不存在"
        case .sourceMissing:
            "源文件已不存在"
        case .fileUnreadable:
            "读取配置文件失败"
        case .notYAML:
            "内容不是 YAML 配置"
        case .unsupportedFormat:
            "格式不支持：该订阅不认本客户端，可在设置更换 UA"
        case .network:
            "网络请求失败，请检查网络后重试"
        case .binaryMissing:
            "内核文件缺失，请重新安装应用"
        case .configInvalid:
            "配置无效，无法使用"
        case .emptyName:
            "名称不能为空"
        case .storageFailure:
            "写入本地文件失败"
        }
    }

    /// 只进日志，不含订阅 URL / 节点信息
    var logDescription: String {
        switch self {
        case .configInvalid(let detail):
            "configInvalid（\(detail)）"
        default:
            String(describing: self)
        }
    }
}
