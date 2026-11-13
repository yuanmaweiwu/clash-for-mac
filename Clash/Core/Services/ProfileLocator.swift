import Foundation
import OSLog

/// 定位本轮启动要用的用户配置（`docs/01-ARCHITECTURE.md` §4）。
///
/// v0.2 前期还没有 `profiles/index.json`（下一轮），所以只有两条来源：
/// 1. `CLASH_PROFILE` 环境变量（**仅 DEBUG**，打包版忽略）——开发期指向任意文件
/// 2. `profiles/` 下恰好一份 `*.yaml` —— 唯一候选直接使用
///
/// 多份配置时返回 `nil`（启动内置空配置），等 `index.json` 决定 active 后再改这里。
enum ProfileLocator {

    static let environmentKey = "CLASH_PROFILE"

    private static let logger = Logger(subsystem: "com.clash.app", category: "profile")

    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        profilesDirectory: URL = AppPaths.profilesDirectory
    ) -> URL? {
        #if DEBUG
        if let path = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            logger.error("\(environmentKey, privacy: .public) 指向的文件不存在：\(url.path, privacy: .public)")
        }
        #endif

        let candidates = yamlFiles(in: profilesDirectory)
        guard candidates.count == 1 else {
            if candidates.count > 1 {
                logger.notice("profiles 下有多份配置（\(candidates.count)），暂不自动选择，等 index.json")
            }
            return nil
        }
        return candidates[0]
    }

    /// 启动日志用：只打文件名，不打完整路径 / 订阅 URL
    static func displayName(for profileURL: URL?) -> String {
        profileURL?.lastPathComponent ?? "内置空配置"
    }

    private static func yamlFiles(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
