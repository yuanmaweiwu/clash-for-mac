import Foundation
import OSLog

/// `~/Library/Application Support/Clash/` 下的目录布局（`docs/01-ARCHITECTURE.md` §3）。
///
/// 目录在首次访问时创建；创建失败只记日志，不让 App 启动崩掉——
/// 后续真正写文件时会给出更具体的错误。
enum AppPaths {

    private static let logger = Logger(subsystem: "com.clash.app", category: "paths")

    /// 根目录
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return ensure(base.appending(path: "Clash", directoryHint: .isDirectory), name: "根目录")
    }()

    /// `profiles/`：用户配置原样保存
    static let profilesDirectory = ensure(
        supportDirectory.appending(path: "profiles", directoryHint: .isDirectory),
        name: "profiles"
    )

    /// `profiles/index.json`：订阅库索引（唯一索引，只有元数据）
    static var profilesIndexURL: URL {
        profilesDirectory.appending(path: "index.json")
    }

    /// `kernel/`：内核共享工作目录（`-d`），geoip.metadb、cache.db 落在这里
    static let kernelDirectory = ensure(
        supportDirectory.appending(path: "kernel", directoryHint: .isDirectory),
        name: "kernel"
    )

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
