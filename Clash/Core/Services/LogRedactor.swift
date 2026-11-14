import Foundation

/// 日志脱敏（`core-process` §7）：本次运行的 API secret + URL 里的 token / key 参数一律打码。
///
/// 只做「确定是凭据」的替换，不猜；拿不到 secret 时（如内核未运行）仍会过滤 URL 参数。
/// 纯函数、无 AppKit / MainActor 依赖：`LogStore` 与单测（`Scripts/unit-tests.sh`）共用同一份。
enum LogRedactor {

    static func redact(_ text: String, secret: String?) -> String {
        var result = text
        if let secret, !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "***")
        }
        return redactCredentials(in: result)
    }

    /// `?token=xxx` / `&key=xxx` / `&access_token=xxx` … → `?token=***`
    static func redactCredentials(in text: String) -> String {
        guard let regex = credentialRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: "$1***"
        )
    }

    private static let credentialRegex = try? NSRegularExpression(
        // 取 `=` 前一个非空白、非 `=` 字符作为前缀（`?` / `&` / 引号都行），
        // 避免把正文里出现的 `token:` 之类误伤；值一直取到分隔符 / 空白为止
        pattern: #"(?i)([?&"'\s](?:token|key|secret|access_token|password|passwd|uuid)=)[^&\s"'<>]+"#,
        options: []
    )
}
