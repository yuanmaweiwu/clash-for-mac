import Foundation

/// 订阅行 / 磁贴的展示派生（§4.2 / §4.8）。
///
/// 规则：缺字段即省，不补占位；用量只在 download + total 都有值时显示。
extension ProfileEntry {

    /// 失败态：`lastError` 非空即标记「更新失败，仍在使用旧配置」
    var isUpdateFailed: Bool { lastError != nil }

    /// 行首来源图标
    var sourceIconName: String { source.kind == .url ? "link" : "doc.text" }

    /// 第二行：更新时间 · 用量 [· 更新失败]
    var detailText: String {
        var parts = [Self.updatedText(updatedAt)]
        if let quotaText { parts.append(quotaText) }
        if isUpdateFailed { parts.append("更新失败，仍在使用旧配置") }
        return parts.joined(separator: " · ")
    }

    /// `12.3/100 GB`；download 或 total 缺失 → nil
    var quotaText: String? {
        guard let info = subscriptionInfo,
              let download = info.download,
              let total = info.total,
              total > 0 else { return nil }

        let gigabyte = 1_073_741_824.0
        let megabyte = 1_048_576.0
        let kilobyte = 1024.0

        if Double(total) >= gigabyte {
            return "\(Self.usage(download, unit: gigabyte))/\(Self.capacity(total, unit: gigabyte)) GB"
        }
        if Double(total) >= megabyte {
            return "\(Self.usage(download, unit: megabyte))/\(Self.capacity(total, unit: megabyte)) MB"
        }
        return "\(Self.usage(download, unit: kilobyte))/\(Self.capacity(total, unit: kilobyte)) KB"
    }

    /// 行尾到期文本（`12/3 到期`）；`expire` 缺失 / 0 → nil
    var expiryText: String? {
        guard let timestamp = subscriptionInfo?.expire, timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return "\(Self.expiryFormatter.string(from: date)) 到期"
    }

    /// 已过期：磁贴副标题追加「· 已过期」
    var isExpired: Bool {
        guard let timestamp = subscriptionInfo?.expire, timestamp > 0 else { return false }
        return Date(timeIntervalSince1970: TimeInterval(timestamp)) < .now
    }

    // MARK: - 格式化

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static func usage(_ bytes: Int, unit: Double) -> String {
        String(format: "%.1f", Double(bytes) / unit)
    }

    private static func capacity(_ bytes: Int, unit: Double) -> String {
        let value = Double(bytes) / unit
        if abs(value - value.rounded()) < 0.05 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private static func updatedText(_ date: Date?) -> String {
        guard let date else { return "尚未更新" }
        let seconds = max(0, Date.now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚更新" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前更新" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前更新" }
        return "\(Int(seconds / 86_400)) 天前更新"
    }
}
