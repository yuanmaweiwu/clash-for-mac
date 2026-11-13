import Foundation

/// TUN 运行目录里有没有 GeoIP / GeoSite 数据库。
///
/// 为什么 App 要管这个：内核以 `-d /Library/Application Support/ClashHelper` 启动，只要订阅里
/// 有 `GEOIP,` / `GEOSITE,` 规则，mihomo 就必须在这个目录里找到 `geoip.metadb`（或 `geoip.dat`）
/// 和 `geosite.dat`。找不到时它会**去 GitHub 下载**——国内基本 90 秒超时，最终表现为
/// 「内核 8 秒内未就绪」，而真正的错误在 root 的 `kernel.log` 里，用户完全看不到。
///
/// 目录是 0755 root:wheel：App 能读**目录项**（所以能做存在性判断），读不到 0600 的日志。
///
/// 实现要点：
/// - 订阅可达 1–5 MB：只做 `Data` 字节扫描（不 `String(contentsOf:)` + `uppercased()` 造两份副本）
/// - 结果按 (配置文件路径, mtime) 缓存：一次启动里 gate 会问 1–2 次，第二次不再读盘
/// - 扫描放 `Task.detached`：判定发生在内核启动 / 开 TUN 的路径上，不能阻塞主线程
enum TunGeodataProbe {

    /// 订阅里是否需要地理数据库
    static func profileNeedsGeodata(_ profileURL: URL?) async -> Bool {
        let requirements = await requirements(for: profileURL)
        return requirements.geoip || requirements.geosite
    }

    /// 缺哪些文件；空数组 = 齐全或不需要
    static func missing(profileURL: URL?) async -> [String] {
        let requirements = await requirements(for: profileURL)

        var missing: [String] = []
        if requirements.geoip, !hasGeoIPDatabase() {
            missing.append("geoip.metadb")
        }
        if requirements.geosite, !hasGeoSiteDatabase() {
            missing.append("geosite.dat")
        }
        return missing
    }

    /// 给用户看的一句话；`nil` = 没问题
    static func missingDescription(profileURL: URL?) async -> String? {
        let missing = await missing(profileURL: profileURL)
        guard !missing.isEmpty else { return nil }
        return "内核缺少 \(missing.joined(separator: "、"))（运行目录 \(HelperLayout.supportDirectory)），"
            + "启动时会尝试在线下载并超时；请在设置里「重新安装…」管理员组件，把已下载的地理数据拷入该目录"
    }

    // MARK: - 规则扫描

    private struct Requirements: Sendable, Equatable {
        var geoip = false
        var geosite = false
    }

    /// 进程内缓存：键是文件路径，另存 mtime；mtime 变了（更新订阅）就重扫。
    ///
    /// 用锁而不是 actor：调用方在 `Task.detached` 里，同步取值更直接，
    /// 也不会把主 actor 的隔离带进后台线程。
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var path: String?
        private var modified: Date?
        private var cached = Requirements()

        func value(for url: URL, modified date: Date) -> Requirements? {
            lock.lock()
            defer { lock.unlock() }
            guard path == url.path, modified == date else { return nil }
            return cached
        }

        func store(_ requirements: Requirements, for url: URL, modified date: Date) {
            lock.lock()
            path = url.path
            modified = date
            cached = requirements
            lock.unlock()
        }
    }

    private static let cache = Cache()

    private static func requirements(for profileURL: URL?) async -> Requirements {
        guard let profileURL else { return Requirements() }

        return await Task.detached(priority: .userInitiated) {
            // 用 `attributesOfItem` 而不是 `URL.resourceValues`：后者会按 URL 实例缓存 mtime，
            // 同一个 URL 反复传进来时会把「刚更新过的订阅」当成旧结果。
            let modified = (try? FileManager.default.attributesOfItem(atPath: profileURL.path))?[
                .modificationDate
            ] as? Date ?? .distantPast
            if let cached = cache.value(for: profileURL, modified: modified) { return cached }

            // `.mappedIfSafe`：大文件走 mmap，不把整份正文复制进堆
            guard let data = try? Data(contentsOf: profileURL, options: .mappedIfSafe) else {
                return Requirements()
            }
            let requirements = Requirements(
                geoip: contains("geoip,", in: data),
                geosite: contains("geosite,", in: data)
            )
            cache.store(requirements, for: profileURL, modified: modified)
            return requirements
        }.value
    }

    /// 大小写不敏感地找 `geoip,` / `geosite,` 这 6–8 个字节。
    ///
    /// 不用 `String.uppercased()`：那会给几 MB 的订阅再造一份副本；这里直接在 `Data`
    /// 的字节上按 ASCII 折叠比较，零额外分配。
    private static func contains(_ token: String, in data: Data) -> Bool {
        let folded = token.utf8.map { asciiLower($0) }
        guard !folded.isEmpty, data.count >= folded.count else { return false }

        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            let lastStart = raw.count - folded.count
            var start = 0
            while start <= lastStart {
                var offset = 0
                while offset < folded.count,
                      asciiLower(base[start + offset]) == folded[offset] {
                    offset += 1
                }
                if offset == folded.count { return true }
                start += 1
            }
            return false
        }
    }

    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
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
}
