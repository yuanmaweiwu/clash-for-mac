import Foundation
import OSLog

/// 日志目录轮转：**启动时清理一次**，只保留最近 7 天。
///
/// 口径选择「按天保留 7 天」而不是「总量 ≤20 MB」：
/// App 日志本来就按天一个文件（`clash-YYYYMMDD.log`），删整天文件不会截断正在写的当天日志，
/// 也和用户「最近一周」的心智一致；按总量压需要在写入时反复 stat + 截断，成本更高。
///
/// 只管 `~/Library/Application Support/Clash/logs/` 与 `clash-*.log` 命名的文件：
/// - 内存里的 WS 日志由 `LogStore` 的 500 条环形缓冲兜底，与磁盘文件无关
/// - helper 的 `kernel.log` / `helper.log` 在 root 目录，App 无权限读写，
///   由 `HelperLog` 自己按 2 MB 截断（口径不同，且必须留在 helper 侧）
enum LogRetention {

    /// 保留窗口：7 天
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    private static let logger = Logger(subsystem: "com.clash.app", category: "paths")

    /// 启动时调用：扫描与删除放后台，失败只记日志，绝不阻塞启动。
    static func pruneAtStartup(directory: URL = AppPaths.logsDirectory) {
        Task.detached(priority: .utility) {
            prune(directory: directory, now: .now)
        }
    }

    /// 同步实现（自检可直接调用）；`now` 可注入，便于验证边界。
    static func prune(directory: URL, now: Date = .now) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]

        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = now.addingTimeInterval(-retention)
        var removed = 0

        for file in files {
            guard file.lastPathComponent.hasPrefix("clash-"),
                  file.pathExtension == "log",
                  let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }

            do {
                try fileManager.removeItem(at: file)
                removed += 1
            } catch {
                logger.error(
                    "清理过期日志失败 \(file.lastPathComponent, privacy: .public)：\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if removed > 0 {
            logger.notice("日志轮转：已删除 \(removed) 个超过 7 天的日志文件")
        }
    }
}
