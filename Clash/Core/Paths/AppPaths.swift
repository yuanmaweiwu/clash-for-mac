import Foundation
import OSLog

/// `~/Library/Application Support/Clash/` 下的目录布局（`docs/01-ARCHITECTURE.md` §3）。
///
/// 目录在首次访问时创建；创建失败只记日志，不让 App 启动崩掉——
/// 后续真正写文件时会给出更具体的错误。
enum AppPaths {

    private static let logger = Logger(subsystem: "com.clash.app", category: "paths")

    /// CLI 夹具的数据根覆盖（**仅 DEBUG**）：`CLASH_DATA_ROOT=/tmp/xxx` 时所有路径都落到它下面，
    /// 自检 / 基准不允许碰真实用户数据。
    ///
    /// 只读一次环境变量：App 启动后不再变（`static let` 的求值顺序天然保证）。
    /// Release 恒为 nil——生产路径只有一个。
    static let dataRootOverride: URL? = {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["CLASH_DATA_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        #else
        return nil
        #endif
    }()

    /// 根目录（`CLASH_DATA_ROOT` 覆盖时就是它本身）
    static let supportDirectory: URL = {
        if let dataRootOverride {
            return ensure(dataRootOverride, name: "根目录（CLASH_DATA_ROOT）")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return ensure(base.appending(path: "Clash", directoryHint: .isDirectory), name: "根目录")
    }()

    /// `settings.json`：应用设置（原子写 0600，见 `SettingsStore`）
    static var settingsURL: URL {
        supportDirectory.appending(path: "settings.json")
    }

    /// `~/Library/Caches/com.clash.app`：可再生的缓存（「完全清理」会删掉）。
    ///
    /// 不在这里 `ensure()`：没有缓存时不该凭空建目录，删除时也允许不存在。
    /// `CLASH_DATA_ROOT` 覆盖时落到数据根下的 `Caches/`，让夹具的清理目标也在临时目录里。
    static var cachesDirectory: URL {
        if let dataRootOverride {
            return dataRootOverride.appending(path: "Caches", directoryHint: .isDirectory)
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Caches", directoryHint: .isDirectory)
        return base.appending(path: "com.clash.app", directoryHint: .isDirectory)
    }

    /// `~/Library/Preferences/com.clash.app.plist`（「完全清理」按存在与否删除）
    ///
    /// `CLASH_DATA_ROOT` 覆盖时改成数据根下的 `Preferences.plist`：夹具绝不能删真实偏好。
    static var preferencesPlistURL: URL {
        if let dataRootOverride {
            return dataRootOverride.appending(path: "Preferences.plist")
        }
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library", directoryHint: .isDirectory)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.clash.app"
        return base.appending(path: "Preferences/\(bundleID).plist")
    }

    /// `profiles/`：用户配置原样保存
    static let profilesDirectory = ensure(
        supportDirectory.appending(path: "profiles", directoryHint: .isDirectory),
        name: "profiles"
    )

    /// `profiles/index.json`：订阅库索引（唯一索引，只有元数据）
    static var profilesIndexURL: URL {
        profilesDirectory.appending(path: "index.json")
    }

    /// `kernel/`：内核共享工作目录（`-d`），同时存放运行时下载的 mihomo 与 geodata
    /// （ADR-0012：内核不随包分发，首次需要时下载到这里）
    static let kernelDirectory = ensure(
        supportDirectory.appending(path: "kernel", directoryHint: .isDirectory),
        name: "kernel"
    )

    /// 运行时下载的内核二进制（本地内核直启 / TUN 安装脚本的来源）
    static var kernelBinaryURL: URL {
        kernelDirectory.appending(path: "mihomo")
    }

    /// 已安装内核的版本号（`kernel/VERSION`）：下载 / 内置拷出 / 升级后都会写，
    /// 设置页的「当前版本」优先读它，缺失才回退到包内 `Resources/Kernel/VERSION`
    static var kernelVersionURL: URL {
        kernelDirectory.appending(path: "VERSION")
    }

    /// GeoIP 数据库（`GEOIP,` 规则必需）
    static var geoIPDatabaseURL: URL {
        kernelDirectory.appending(path: "geoip.metadb")
    }

    /// GeoSite 数据库（`GEOSITE,` 规则需要，下载失败只告警）
    static var geoSiteDatabaseURL: URL {
        kernelDirectory.appending(path: "geosite.dat")
    }

    /// `runtime/`：每次启动重建的最终配置
    static let runtimeDirectory = ensure(
        supportDirectory.appending(path: "runtime", directoryHint: .isDirectory),
        name: "runtime"
    )

    /// `logs/`：内核 stdout/stderr
    static let logsDirectory = ensure(
        supportDirectory.appending(path: "logs", directoryHint: .isDirectory),
        name: "logs"
    )

    /// 系统代理快照（v0.2 起使用）
    static var systemProxySnapshotURL: URL {
        supportDirectory.appending(path: "systemproxy-snapshot.json")
    }

    /// 节点延迟缓存（内核 `history` 是内存态，退出后靠这里恢复）
    static var latencyCacheURL: URL {
        supportDirectory.appending(path: "latency-cache.json")
    }

    /// 用户手动选中的节点（组名 → 节点名）。本地内核与 TUN 内核的 `-d` 目录不同，
    /// `store-selected` 的两份 cache.db 不共享，启动时靠这里显式恢复。
    static var selectionURL: URL {
        supportDirectory.appending(path: "selection.json")
    }

    /// 当前启动使用的 runtime 配置（无 profile 时的最小可用配置）
    static var runtimeConfigURL: URL {
        runtimeDirectory.appending(path: "runtime.yaml")
    }

    /// `logs/clash-YYYYMMDD.log`
    static func logFileURL(for date: Date = .now) -> URL {
        logsDirectory.appending(path: "clash-\(dayStamp(for: date)).log")
    }

    private static func dayStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    @discardableResult
    private static func ensure(_ url: URL, name: String) -> URL {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            logger.error("创建\(name, privacy: .public)目录失败：\(error.localizedDescription, privacy: .public)")
        }
        return url
    }
}
