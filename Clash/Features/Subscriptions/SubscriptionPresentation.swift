import Foundation

/// 订阅管理页的三态（§4.8）：读取中 / 读取失败 / 已加载（含空库）。
///
/// 视图只做三选一渲染，不再用「列表为空」同时表达「还没读完」「读失败」「真的没有订阅」。
enum SubscriptionPanelState: Equatable, Sendable {
    case loading
    case failed(String)
    case loaded
}

/// 订阅管理页的展示派生
extension ProfileStoreLoadState {
    var panelState: SubscriptionPanelState {
        switch self {
        case .loading: .loading
        case .ready: .loaded
        case .failed(let message): .failed(message)
        }
    }
}

/// 订阅磁贴的内容（§4.2）：商家名 / 用量 / 到期缺字段即省行。
///
/// 视图只负责摆位置与配色，不再判断「有没有字段」，避免格式化在视图里再写一遍。
struct SubscriptionTileContent: Equatable, Sendable {
    /// 商家名（激活那条，可带「· 更新失败」）；nil = 还没导入 → 显示「未添加」
    var name: String?
    /// 用量 `100.4/128 GB`；缺 `download` / `total` → nil（不画条）
    var quotaText: String?
    /// 用量比例，可 > 1 表示超额；nil = 不画条
    var usageFraction: Double?
    /// 到期 `12/3 到期`；已过期 →「已过期」；缺 `expire` → nil（不占行）
    var expiryText: String?
    /// 已过期：到期行转 `error`
    var isExpired: Bool = false
    /// 库内条数；> 1 时右上角徽标
    var badgeCount: Int = 0
    /// VoiceOver 一句话（已含名称 / 用量 / 到期 / 条数）
    var accessibilityValue: String

    /// 未导入配置：只剩标题 +「未添加」
    static let empty = SubscriptionTileContent(accessibilityValue: "未导入订阅")
}

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

    /// 已过期：`expire` 早于当前时间（磁贴到期行转「已过期」+ `error`）
    var isExpired: Bool {
        guard let timestamp = subscriptionInfo?.expire, timestamp > 0 else { return false }
        return Date(timeIntervalSince1970: TimeInterval(timestamp)) < .now
    }

    /// 单独的相对更新时间（底栏 / 行内共用）：刚刚更新 / N 分钟前更新 / N 小时前更新 / N 天前更新
    var updatedAgoText: String { Self.updatedText(updatedAt) }

    // MARK: - 订阅磁贴（§4.2）

    /// 磁贴四行内容。名称带「· 更新失败」；「已过期」只由到期行表达，不重复进名称。
    func tileContent(badgeCount: Int) -> SubscriptionTileContent {
        var title = name
        if isUpdateFailed { title += " · 更新失败" }
        let usage = tileUsage

        return SubscriptionTileContent(
            name: title,
            quotaText: usage?.text,
            usageFraction: usage?.fraction,
            expiryText: tileExpiryText,
            isExpired: isExpired,
            badgeCount: badgeCount,
            accessibilityValue: tileAccessibilityValue(badgeCount: badgeCount)
        )
    }

    /// 磁贴用量：文案与比例必须同源，缺字段整行省掉（不画条）
    private var tileUsage: (text: String, fraction: Double)? {
        guard let info = subscriptionInfo,
              let download = info.download,
              let total = info.total, total > 0,
              let text = quotaText else { return nil }
        return (text, Double(download) / Double(total))
    }

    /// 磁贴到期行：`12/3 到期`；已过期 →「已过期」（短，3 字）
    private var tileExpiryText: String? {
        guard let timestamp = subscriptionInfo?.expire, timestamp > 0 else { return nil }
        return isExpired ? "已过期" : expiryText
    }

    /// VoiceOver 一句话；单位读中文（§6.1：不朗读 `GB` 这类缩写）
    private func tileAccessibilityValue(badgeCount: Int) -> String {
        var parts = [name]
        if let info = subscriptionInfo,
           let download = info.download,
           let total = info.total, total > 0 {
            let used = Self.spokenAmount(download)
            let capacity = Self.spokenAmount(total)
            parts.append("已用 \(used)，共 \(capacity)")
        }
        if let expiry = spokenExpiry {
            parts.append(isExpired ? "\(expiry)已过期" : "\(expiry)到期")
        }
        if isUpdateFailed { parts.append("更新失败，仍在使用旧配置") }
        if badgeCount > 1 { parts.append("共 \(badgeCount) 条订阅") }
        return parts.joined(separator: "，")
    }

    /// 朗读用日期：`12 月 3 日`（与 `expiryText` 同一时区）
    private var spokenExpiry: String? {
        guard let timestamp = subscriptionInfo?.expire, timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let parts = Calendar(identifier: .gregorian).dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return nil }
        return "\(month) 月 \(day) 日"
    }

    // MARK: - 格式化

    /// 朗读用量：`128.0 吉字节` 会读成「一百二十八点零」，整数一律不带小数位（与屏幕上的 `128 GB` 对齐）
    private static func spokenAmount(_ bytes: Int) -> String {
        TrafficFormat.spokenBytes(Int64(bytes)).replacingOccurrences(of: ".0 ", with: " ")
    }

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
