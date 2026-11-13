import Foundation
import OSLog

/// 定位本轮启动要用的用户配置（`docs/01-ARCHITECTURE.md` §4）。
///
/// 唯一来源：`profiles/index.json` 的 `activeProfileID` → `profiles/<id>.yaml`。
/// 「目录里恰好一份就用它」的启发式已删除：多份配置并存时只有 active 生效。
///
/// `CLASH_PROFILE` 环境变量仍保留为 **DEBUG** 覆盖（优先级最高），指向任意文件。
enum ProfileLocator {

    static let environmentKey = "CLASH_PROFILE"

    private static let logger = Logger(subsystem: "com.clash.app", category: "profile")

    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        profilesDirectory: URL = AppPaths.profilesDirectory,
        indexURL: URL? = nil
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

        let index = indexURL ?? profilesDirectory.appending(path: "index.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return nil }

        let parsed: ProfileIndex
        do {
            parsed = try ProfileIndexFile.load(from: index)
        } catch {
            logger.error("index.json 读取失败，本轮用内置空配置：\(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let id = parsed.activeProfileID, !id.isEmpty else { return nil }

        let candidate = profilesDirectory.appending(path: "\(id).yaml")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            logger.error("active 配置文件缺失：id=\(id, privacy: .public)")
            return nil
        }
        return candidate
    }

    /// 启动日志用：只打文件名，不打完整路径 / 订阅 URL
    static func displayName(for profileURL: URL?) -> String {
        profileURL?.lastPathComponent ?? "内置空配置"
    }
}
