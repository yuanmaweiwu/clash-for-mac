import Foundation

/// `GET /connections` 里的一条活动连接（`core-process` §5）。
///
/// 只保留面板展示需要的字段：域名 / IP、进程、规则、链路、累计字节、开始时间。
/// `chains` 里混着策略组与内置出口（`DIRECT` / `REJECT` …），面板的「节点」取第一个非内置项。
struct ConnectionEntry: Identifiable, Decodable, Sendable, Equatable {
    let id: String
    /// `metadata.host`，没有域名就退回 `metadata.destinationIP`
    let host: String
    /// `metadata.process` 取末段文件名（`/usr/bin/curl` → `curl`）
    let processName: String?
    /// 规则类型 + 载荷，如 `DomainSuffix(example.com)`；无载荷时只有类型
    let rule: String
    /// 完整链路，内核顺序
    let chains: [String]
    /// 该连接累计上行字节
    let upload: Int64
    /// 该连接累计下行字节
    let download: Int64
    /// 连接建立时间（内核的 RFC3339，解析失败为 nil）
    let start: Date?

    /// 链路里的出口节点；全内置（如 `DIRECT`）时为 nil
    ///
    /// 内核顺序是「出口节点 → 外层策略组」（v1.19.34 实测：`["🇭🇰 香港 | 00", "机场A"]`），
    /// 所以取**第一个**非内置项；全内置链路说明走的是直连 / 拒绝，没有节点可展示。
    var node: String? {
        chains.first { !Self.builtinChainNames.contains($0.uppercased()) }
    }

    /// 内置出口 / 容器名，不作为「节点」展示
    private static let builtinChainNames: Set<String> = [
        "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"
    ]

    // MARK: - 解码

    private enum CodingKeys: String, CodingKey {
        case id, metadata, upload, download, start, chains, rule, rulePayload
    }

    private enum MetadataKeys: String, CodingKey {
        case host, destinationIP, process
    }

    private struct Metadata: Decodable, Sendable {
        let host: String?
        let destinationIP: String?
        let process: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        upload = try container.decodeIfPresent(Int64.self, forKey: .upload) ?? 0
        download = try container.decodeIfPresent(Int64.self, forKey: .download) ?? 0
        chains = try container.decodeIfPresent([String].self, forKey: .chains) ?? []

        let ruleType = try container.decodeIfPresent(String.self, forKey: .rule) ?? ""
        let payload = try container.decodeIfPresent(String.self, forKey: .rulePayload) ?? ""
        rule = payload.isEmpty ? ruleType : "\(ruleType)(\(payload))"

        if let rawStart = try container.decodeIfPresent(String.self, forKey: .start) {
            start = Self.parseStart(rawStart)
        } else {
            start = nil
        }

        let metadata = try container.decodeIfPresent(Metadata.self, forKey: .metadata)
        host = Self.nonEmpty(metadata?.host) ?? metadata?.destinationIP ?? ""
        processName = Self.processName(from: metadata?.process)
    }

    /// `metadata.process` 可能是绝对路径，只留末段文件名
    private static func processName(from raw: String?) -> String? {
        guard let raw = nonEmpty(raw) else { return nil }
        return nonEmpty((raw as NSString).lastPathComponent)
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// 内核用 RFC3339Nano；带 / 不带小数秒各试一次
    private static func parseStart(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: .iso8601) { return date }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try? Date(raw, strategy: fractional)
    }
}

#if DEBUG
extension ConnectionEntry {
    /// 预览夹具：直接构造一条连接（截图走查用，不参与解码）
    init(previewHost: String, processName: String?, rule: String, node: String?, upload: Int64, download: Int64) {
        self.id = UUID().uuidString
        self.host = previewHost
        self.processName = processName
        self.rule = rule
        self.chains = [node].compactMap { $0 } + ["机场A"]
        self.upload = upload
        self.download = download
        self.start = .now.addingTimeInterval(-180)
    }
}
#endif
