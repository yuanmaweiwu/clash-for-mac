import Foundation

/// TUN 运行目录里有没有 GeoIP / GeoSite 数据库。
///
/// 为什么 App 要管这个：内核以 `-d /Library/Application Support/ClashHelper` 启动，只要订阅里
/// 有 `GEOIP,` / `GEOSITE,` 规则，mihomo 就必须在这个目录里找到 `geoip.metadb`（或 `geoip.dat`）
/// 和 `geosite.dat`。找不到时它会**去 GitHub 下载**——国内基本 90 秒超时，最终表现为
/// 「内核 8 秒内未就绪」，而真正的错误在 root 的 `kernel.log` 里，用户完全看不到。
///
/// 目录是 0755 root:wheel：App 能读**目录项**（所以能做存在性判断），读不到 0600 的日志。
enum TunGeodataProbe {

    /// 订阅里是否需要地理数据库
    static func profileNeedsGeodata(_ profileURL: URL?) -> Bool {
        guard let text = profileText(profileURL) else { return false }
        let upper = text.uppercased()
        return upper.contains("GEOIP,") || upper.contains("GEOSITE,")
    }

    /// 缺哪些文件；空数组 = 齐全或不需要
    static func missing(profileURL: URL?) -> [String] {
        guard let text = profileText(profileURL) else { return [] }
        let upper = text.uppercased()

        var missing: [String] = []
        if upper.contains("GEOIP,"), !hasGeoIPDatabase() {
            missing.append("geoip.metadb")
        }
        if upper.contains("GEOSITE,"), !hasGeoSiteDatabase() {
            missing.append("geosite.dat")
        }
        return missing
    }

    /// 给用户看的一句话；`nil` = 没问题
    static func missingDescription(profileURL: URL?) -> String? {
        let missing = missing(profileURL: profileURL)
        guard !missing.isEmpty else { return nil }
        return "内核缺少 \(missing.joined(separator: "、"))（运行目录 \(HelperLayout.supportDirectory)），"
            + "启动时会尝试在线下载并超时；请把文件放进该目录，或重新授权安装组件"
    }

    // MARK: - 文件

    private static func hasGeoIPDatabase() -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: HelperLayout.supportDirectory + "/geoip.metadb")
            || fileManager.fileExists(atPath: HelperLayout.supportDirectory + "/geoip.dat")
    }

    private static func hasGeoSiteDatabase() -> Bool {
        FileManager.default.fileExists(atPath: HelperLayout.supportDirectory + "/geosite.dat")
    }

    private static func profileText(_ profileURL: URL?) -> String? {
        guard let profileURL else { return nil }
        return try? String(contentsOf: profileURL, encoding: .utf8)
    }
}
