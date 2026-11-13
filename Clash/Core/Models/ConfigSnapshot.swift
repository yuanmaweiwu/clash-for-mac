import Foundation

/// `GET /configs` 里面板关心的字段（模式与端口）。
///
/// 内核会回几十个字段，这里只声明需要的，其余忽略。
struct ConfigSnapshot: Decodable, Sendable, Equatable {
    let mode: String?
    let mixedPort: Int?
    let port: Int?
    let socksPort: Int?

    private enum CodingKeys: String, CodingKey {
        case mode
        case port
        case mixedPort = "mixed-port"
        case socksPort = "socks-port"
    }

    /// 内核模式；解析不出来时为 nil（调用方保留当前值）
    var proxyMode: ProxyMode? {
        guard let mode else { return nil }
        return ProxyMode(rawValue: mode)
    }
}
