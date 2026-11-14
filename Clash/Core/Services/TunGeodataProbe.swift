import Foundation

/// TUN 运行目录里有没有 GeoIP / GeoSite 数据库。
///
/// 为什么 App 要管这个：内核以 `-d /Library/Application Support/ClashHelper` 启动，只要订阅里
/// 用到 `geoip` / `geosite`，mihomo 就必须在这个目录里找到 `geoip.metadb`（或 `geoip.dat`）
/// 和 `geosite.dat`。找不到时它会**去 GitHub 下载**——国内基本 90 秒超时，最终表现为
/// 「内核 8 秒内未就绪」，而真正的错误在 root 的 `kernel.log` 里（0600），用户完全看不到。
///
/// 需求来源不止规则：`nameserver-policy` 里的 `'geosite:category-ads-all'` 同样会让内核去下载
/// geosite（真机事故：只扫 `geosite,` 漏判 → TUN 静默失效）。
///
/// 目录是 0755 root:wheel：App 能读**目录项**（所以能做存在性判断），读不到 0600 的日志。
///
/// 实现要点：
/// - 订阅可达 1–5 MB：只做 `Data` 字节扫描（不 `String(contentsOf:)` + `uppercased()` 造两份副本）
/// - 两个词在一次遍历里判完；命中即提前返回
/// - 结果按 (配置文件路径, mtime) 缓存：一次启动里 gate 会问 1–2 次，第二次不再读盘
/// - 扫描放 `Task.detached`：判定发生在内核启动 / 开 TUN 的路径上，不能阻塞主线程
enum TunGeodataProbe {

    /// 缺什么、缺在哪一侧。
    ///
    /// 分两边的意义：用户内核目录可以由 App 自己下载补齐，helper 运行目录只能靠重装组件拷入
    /// （安装脚本从 `~/Library/Application Support/Clash/kernel/` 拷 `geoip.metadb` / `geosite.dat`）。
    struct Gap: Sendable, Equatable {
        /// 用户内核目录缺哪些（`KernelService.ensureGeodataIfNeeded` 负责下载）
        var userDirectory: [String] = []
        /// helper 运行目录缺哪些（只有「重新安装组件」能拷进去）
        var helperDirectory: [String] = []

        var isEmpty: Bool { userDirectory.isEmpty && helperDirectory.isEmpty }
    }

    /// 订阅里是否需要地理数据库
    static func profileNeedsGeodata(_ profileURL: URL?) async -> Bool {
        let requirements = await requirements(for: profileURL)
        return requirements.geoip || requirements.geosite
    }

    /// 需要哪些文件、两侧各缺哪些；`isEmpty` = 齐全或不需要
    static func gap(profileURL: URL?) async -> Gap {
        let requirements = await requirements(for: profileURL)
        guard requirements.geoip || requirements.geosite else { return Gap() }

        var gap = Gap()
        if requirements.geoip {
            if !exists(AppPaths.geoIPDatabaseURL.path) { gap.userDirectory.append("geoip.metadb") }
            if !hasGeoIPDatabase() { gap.helperDirectory.append("geoip.metadb") }
        }
        if requirements.geosite {
            if !exists(AppPaths.geoSiteDatabaseURL.path) { gap.userDirectory.append("geosite.dat") }
            if !hasGeoSiteDatabase() { gap.helperDirectory.append("geosite.dat") }
        }
        return gap
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
            let requirements = scan(data)
            cache.store(requirements, for: profileURL, modified: modified)
            return requirements
        }.value
    }

    /// 一次字节遍历，同时判 `geoip` / `geosite`。
    ///
    /// 识别三种写法（都是 mihomo 真实配置里的来源）：
    /// - 规则语法：`GEOSITE,category-ads-all,REJECT`、`GEOIP,CN,DIRECT`
    /// - DNS 策略冒号形式：`'geosite:category-ads-all'`、`'geosite:cn,geolocation-cn'`
    /// - 裸词：`RULE-SET` / provider 名 / 文件名里出现的 `geosite-cn`、`geosite.dat` 等
    ///
    /// **误判成本**：多判一次 = 重装时多拷一份已经存在的数据文件（本地 `cp`，几 MB）；
    /// 漏判的代价 = root 内核去 jsdelivr 下载 → 国内超时 → 8 秒后静默失败，用户读不到
    /// 0600 的 kernel.log。所以这里**宁可多判**：只要出现独立的 `geoip` / `geosite` 词
    /// 就当作需要，不去区分它出现在规则、DNS 策略还是 `geox-url` 里。
    private static func scan(_ data: Data) -> Requirements {
        var requirements = Requirements()

        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            var index = 0
            while index < count {
                if asciiLower(base[index]) != UInt8(ascii: "g") {
                    index += 1
                    continue
                }
                // `geo` 前缀：两个词共用
                guard index + 4 < count,
                      asciiLower(base[index + 1]) == UInt8(ascii: "e"),
                      asciiLower(base[index + 2]) == UInt8(ascii: "o") else {
                    index += 1
                    continue
                }

                switch asciiLower(base[index + 3]) {
                case UInt8(ascii: "i"):
                    // `geoip` + 词边界
                    if index + 5 < count,
                       asciiLower(base[index + 4]) == UInt8(ascii: "p"),
                       isWordBoundary(base[index + 5]) {
                        requirements.geoip = true
                        index += 5
                    } else {
                        index += 1
                    }
                case UInt8(ascii: "s"):
                    // `geosite` + 词边界
                    if index + 7 < count,
                       asciiLower(base[index + 4]) == UInt8(ascii: "i"),
                       asciiLower(base[index + 5]) == UInt8(ascii: "t"),
                       asciiLower(base[index + 6]) == UInt8(ascii: "e"),
                       isWordBoundary(base[index + 7]) {
                        requirements.geosite = true
                        index += 7
                    } else {
                        index += 1
                    }
                default:
                    index += 1
                }

                if requirements.geoip, requirements.geosite { return }
            }
        }

        return requirements
    }

    /// 词尾必须是分隔符（`,` `:` `-` `.` 引号 / 换行…），不能还是字母数字或下划线，
    /// 否则 `geography` / `geolocation` 这类词会被误判。
    private static func isWordBoundary(_ byte: UInt8) -> Bool {
        let lowered = asciiLower(byte)
        if lowered >= UInt8(ascii: "a"), lowered <= UInt8(ascii: "z") { return false }
        if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") { return false }
        return byte != UInt8(ascii: "_")
    }

    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    // MARK: - 文件

    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static func hasGeoIPDatabase() -> Bool {
        exists(HelperLayout.supportDirectory + "/geoip.metadb")
            || exists(HelperLayout.supportDirectory + "/geoip.dat")
    }

    private static func hasGeoSiteDatabase() -> Bool {
        exists(HelperLayout.supportDirectory + "/geosite.dat")
    }
}
