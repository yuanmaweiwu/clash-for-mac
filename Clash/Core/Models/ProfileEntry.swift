import Foundation

/// `profiles/index.json` 的索引文档（`docs/01-ARCHITECTURE.md` §4.1）。
///
/// 只存元数据，配置正文一律在 `profiles/<id>.yaml`。
/// 「同一时刻只有一条 active」由 `activeProfileID` 表达，不做多选。
struct ProfileIndex: Codable, Sendable, Equatable {
    var activeProfileID: String?
    var profiles: [ProfileEntry]

    static let empty = ProfileIndex(activeProfileID: nil, profiles: [])

    init(activeProfileID: String?, profiles: [ProfileEntry]) {
        self.activeProfileID = activeProfileID
        self.profiles = profiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeProfileID = try container.decodeIfPresent(String.self, forKey: .activeProfileID)
        profiles = try container.decodeIfPresent([ProfileEntry].self, forKey: .profiles) ?? []
    }

    /// 空库也显式写 `"activeProfileID": null`，与架构文档的片段一致
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activeProfileID, forKey: .activeProfileID)
        try container.encode(profiles, forKey: .profiles)
    }

    private enum CodingKeys: String, CodingKey {
        case activeProfileID, profiles
    }
}

/// 订阅库里的条目。`id` 决定落盘文件名（`profiles/<id>.yaml`），显示名可随时改。
struct ProfileEntry: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var source: ProfileSource
    /// 最后一次**成功**拉取 / 导入的时间；从未成功为 nil
    var updatedAt: Date?
    /// 建议更新间隔（小时）：0 = 手动；只存字段，调度器在下一轮接
    var autoUpdateHours: Int
    /// 最后一次**尝试**更新时间（成功或失败都写）
    var lastAttemptAt: Date?
    /// 最近一次失败的用户文案；成功后清空
    var lastError: String?
    /// `subscription-userinfo` 映射；缺字段留空，不猜
    var subscriptionInfo: ProfileSubscriptionInfo?
    /// 首屏 pin 的组名：只是 UI 偏好，不注入 runtime
    var pinnedGroups: [String]
    /// `Profile-Web-Page-Url`：订阅管理页（续费入口）；旧索引没有该字段
    var webPageURL: String?

    init(
        id: String,
        name: String,
        source: ProfileSource,
        updatedAt: Date? = nil,
        autoUpdateHours: Int = 0,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil,
        subscriptionInfo: ProfileSubscriptionInfo? = nil,
        pinnedGroups: [String] = [],
        webPageURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.updatedAt = updatedAt
        self.autoUpdateHours = autoUpdateHours
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.subscriptionInfo = subscriptionInfo
        self.pinnedGroups = pinnedGroups
        self.webPageURL = webPageURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, source, updatedAt, autoUpdateHours, lastAttemptAt, lastError
        case subscriptionInfo, pinnedGroups, webPageURL
    }

    /// 手写解码：索引里允许只有 `id/name/source/autoUpdateHours`（架构 §4.1 的 `p_02` 就是这种）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(ProfileSource.self, forKey: .source)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        autoUpdateHours = try container.decodeIfPresent(Int.self, forKey: .autoUpdateHours) ?? 0
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        subscriptionInfo = try container.decodeIfPresent(ProfileSubscriptionInfo.self, forKey: .subscriptionInfo)
        pinnedGroups = try container.decodeIfPresent([String].self, forKey: .pinnedGroups) ?? []
        webPageURL = try container.decodeIfPresent(String.self, forKey: .webPageURL)
    }

    /// 显式写 null（而不是省键），与架构文档里的片段保持一致
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(source, forKey: .source)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(autoUpdateHours, forKey: .autoUpdateHours)
        try container.encode(lastAttemptAt, forKey: .lastAttemptAt)
        try container.encode(lastError, forKey: .lastError)
        try container.encode(subscriptionInfo, forKey: .subscriptionInfo)
        try container.encode(pinnedGroups, forKey: .pinnedGroups)
        try container.encode(webPageURL, forKey: .webPageURL)
    }
}

/// 配置来源：URL 订阅或本地文件。两者都原样保存正文，不在库里区分处理。
struct ProfileSource: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case url
        case file
    }

    var kind: Kind
    var url: String?
    var path: String?

    init(kind: Kind, url: String? = nil, path: String? = nil) {
        self.kind = kind
        self.url = url
        self.path = path
    }
}

/// `subscription-userinfo` 响应头：`upload=…; download=…; total=…; expire=…`
///
/// 全部可选：实测有的机场不给 `expire`。`expire` 是 Unix 秒。
struct ProfileSubscriptionInfo: Codable, Sendable, Equatable {
    var upload: Int?
    var download: Int?
    var total: Int?
    var expire: Int?

    init(upload: Int? = nil, download: Int? = nil, total: Int? = nil, expire: Int? = nil) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
    }

    private enum CodingKeys: String, CodingKey {
        case upload, download, total, expire
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        upload = try container.decodeIfPresent(Int.self, forKey: .upload)
        download = try container.decodeIfPresent(Int.self, forKey: .download)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        expire = try container.decodeIfPresent(Int.self, forKey: .expire)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(upload, forKey: .upload)
        try container.encode(download, forKey: .download)
        try container.encode(total, forKey: .total)
        try container.encode(expire, forKey: .expire)
    }
}

/// `index.json` 的读写编解码器：日期用 ISO8601（带毫秒），键排序、缩进，方便人工看与 diff。
enum ProfileIndexFile {

    /// ISO8601DateFormatter 配置后只读；`nonisolated(unsafe)` 满足 Swift 6 的静态可变状态检查
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalFormatter.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "无法解析时间：\(text)")
            )
        }
        return decoder
    }

    static func load(from url: URL) throws -> ProfileIndex {
        try makeDecoder().decode(ProfileIndex.self, from: Data(contentsOf: url))
    }
}
