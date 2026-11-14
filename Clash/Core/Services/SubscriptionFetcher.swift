import Foundation
import OSLog
import Yams

/// 订阅请求的 User-Agent 策略（`docs/adr/0006-subscription-user-agent.md`）。
///
/// 默认 `mihomo/<bundle 内内核版本>`：与自带内核一致，最不容易被机场识别成陌生客户端。
/// 遇到 422 / 403 / 非 YAML 时换下一个预设重试一次。
enum SubscriptionUserAgent {

    /// 预设 UA（不含默认项）。顺序即重试顺序。
    static let presets = ["clash-verge/v2.7.0", "ClashMetaForAndroid/2.11.6"]

    /// 包内内核版本（`Resources/Kernel/VERSION`，构建时拷入 bundle）
    static let bundledKernelVersion: String = readBundledKernelVersion() ?? "unknown"

    static var defaultUserAgent: String { "mihomo/\(bundledKernelVersion)" }

    /// 默认 UA 失败后要换的那一个
    static var fallbackUserAgent: String? { presets.first }

    private static func readBundledKernelVersion() -> String? {
        for subdirectory in ["Resources/Kernel", "Kernel"] {
            guard let url = Bundle.main.url(forResource: "VERSION", withExtension: nil, subdirectory: subdirectory),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !version.isEmpty { return version }
        }
        return nil
    }
}

/// 一次订阅下载的结果：正文 + 响应头映射（`docs/01-ARCHITECTURE.md` §4.1）。
struct SubscriptionDownload: Sendable, Equatable {
    /// 原始字节：入库时原样落盘，不做规范化回写
    var data: Data
    /// UTF-8 解码后的正文，用于解析与校验
    var text: String
    var statusCode: Int
    var contentType: String?
    /// `Content-Disposition: filename=`（去掉 .yaml / .yml / .txt 后缀）
    var fileName: String?
    /// `Profile-Web-Page-Url`
    var webPageURL: String?
    /// `Profile-Update-Interval`（小时，仅取 > 0）
    var autoUpdateHours: Int?
    /// `subscription-userinfo`；头缺失为 nil，头里缺字段则对应字段为 nil
    var subscriptionInfo: ProfileSubscriptionInfo?
    /// 实际成功的 UA（日志 / 排查用）
    var userAgent: String
}

/// 订阅拉取：`GET` + UA 策略 + 响应头映射。App 侧执行，不需要 root。
///
/// 只做「拿到 YAML 文本」，不做 `mihomo -t`（那是 `ProfileValidator` 的事），
/// 也不落盘（那是 `ProfileStore` 的事）。
enum SubscriptionFetcher {

    static let requestTimeout: TimeInterval = 20

    private static let logger = Logger(subsystem: "com.clash.app", category: "subscription")

    /// 拉取并校验「内容是 YAML 映射」。默认 UA 被拒时换预设重试一次。
    static func fetch(
        url: URL,
        userAgent: String = SubscriptionUserAgent.defaultUserAgent,
        fallbackUserAgent: String? = SubscriptionUserAgent.fallbackUserAgent,
        session: URLSession = .shared,
        timeout: TimeInterval = requestTimeout
    ) async throws -> SubscriptionDownload {
        let first = await attempt(url: url, userAgent: userAgent, session: session, timeout: timeout)
        if let download = first.download { return download }

        // 传输层失败与 UA 无关，不换 UA 白跑一次
        if first.failure == .network { throw ProfileStoreError.network }

        if let fallbackUserAgent, fallbackUserAgent != userAgent {
            logger.notice(
                "默认 UA 被拒（status=\(first.statusCode) type=\(first.contentType ?? "-", privacy: .public)），换预设 UA 重试"
            )
            let second = await attempt(url: url, userAgent: fallbackUserAgent, session: session, timeout: timeout)
            if let download = second.download { return download }
            logRejection(status: second.statusCode, contentType: second.contentType, userAgent: fallbackUserAgent)
        } else {
            logRejection(status: first.statusCode, contentType: first.contentType, userAgent: userAgent)
        }
        // 走到这里只可能是「422/403 或非 YAML」：统一给「格式不支持」文案（ADR-0006）
        throw ProfileStoreError.unsupportedFormat
    }

    // MARK: - 单次请求

    private struct Attempt {
        var download: SubscriptionDownload?
        var failure: ProfileStoreError?
        var statusCode: Int
        var contentType: String?
    }

    private static func attempt(
        url: URL,
        userAgent: String,
        session: URLSession,
        timeout: TimeInterval
    ) async -> Attempt {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("订阅请求失败（\(userAgent, privacy: .public)）：\(error.localizedDescription, privacy: .public)")
            return Attempt(download: nil, failure: .network, statusCode: -1, contentType: nil)
        }

        guard let http = response as? HTTPURLResponse else {
            return Attempt(download: nil, failure: .network, statusCode: -1, contentType: nil)
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        let status = http.statusCode

        guard (200 ..< 300).contains(status) else {
            return Attempt(download: nil, failure: .unsupportedFormat, statusCode: status, contentType: contentType)
        }
        guard let text = String(data: data, encoding: .utf8), isYAMLMapping(text) else {
            return Attempt(download: nil, failure: .notYAML, statusCode: status, contentType: contentType)
        }

        var download = SubscriptionDownload(
            data: data,
            text: text,
            statusCode: status,
            contentType: contentType,
            fileName: parseFileName(http.value(forHTTPHeaderField: "Content-Disposition")),
            webPageURL: http.value(forHTTPHeaderField: "Profile-Web-Page-Url"),
            autoUpdateHours: parseUpdateHours(http.value(forHTTPHeaderField: "Profile-Update-Interval")),
            subscriptionInfo: parseUserInfo(http.value(forHTTPHeaderField: "subscription-userinfo")),
            userAgent: userAgent
        )
        if let fileName = download.fileName, let host = url.host() {
            download.fileName = fileName.isEmpty ? host : fileName
        }
        return Attempt(download: download, failure: nil, statusCode: status, contentType: contentType)
    }

    private static func logRejection(status: Int, contentType: String?, userAgent: String) {
        // 只打状态码与内容类型（不含 URL 参数），ADR-0006 §3
        logger.error(
            "订阅拉取失败 status=\(status) type=\(contentType ?? "-", privacy: .public) ua=\(userAgent, privacy: .public)"
        )
    }

    // MARK: - 解析

    static func isYAMLMapping(_ text: String) -> Bool {
        (try? Yams.load(yaml: text)) as? [AnyHashable: Any] != nil
    }

    /// `upload=123; download=456; total=789; expire=1700000000`
    static func parseUserInfo(_ header: String?) -> ProfileSubscriptionInfo? {
        guard let header, !header.isEmpty else { return nil }
        var info = ProfileSubscriptionInfo()
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            let number = Int(value)
            switch key {
            case "upload": info.upload = number
            case "download": info.download = number
            case "total": info.total = number
            case "expire": info.expire = number
            default: continue
            }
        }
        return info
    }

    /// `Profile-Update-Interval: 1`（小时）。0 / 非法值视为「没有建议」。
    static func parseUpdateHours(_ header: String?) -> Int? {
        guard let header, let hours = Int(header.trimmingCharacters(in: .whitespaces)) else { return nil }
        guard (1 ... 720).contains(hours) else { return nil }
        return hours
    }

    /// `attachment; filename="X.yaml"` / `filename*=UTF-8''%E6%B5%8B%E8%AF%95.yaml`
    static func parseFileName(_ header: String?) -> String? {
        guard let header, !header.isEmpty else { return nil }

        var plain: String?
        var extended: String?

        for parameter in header.split(separator: ";") {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "filename*":
                if let range = value.range(of: "''") {
                    value = String(value[range.upperBound...])
                }
                extended = value.removingPercentEncoding ?? value
            case "filename":
                plain = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            default:
                continue
            }
        }

        guard let name = extended ?? plain else { return nil }
        return displayName(fromHeaderFileName: name)
    }

    /// 头里的文件名只作显示名：去引号 / 换行 / 扩展名，不做路径使用
    static func displayName(fromHeaderFileName name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for suffix in [".yaml", ".yml", ".txt", ".json", ".conf"] where cleaned.lowercased().hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return cleaned
    }
}
