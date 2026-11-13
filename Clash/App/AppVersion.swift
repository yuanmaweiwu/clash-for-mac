import Foundation

/// 本 App 的版本号（面板底栏、关于信息共用）。
///
/// 单一来源是 `Info.plist` 的 `CFBundleShortVersionString`；取不到时不编造，显示 `v—`。
enum AppVersion {

    /// 形如 `0.4.0`；取不到为 nil
    static var short: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 形如 `v0.4.0`；取不到为 `v—`
    static var display: String {
        guard let short else { return "v—" }
        return "v\(short)"
    }
}
