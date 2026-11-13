import Foundation
import Observation
import OSLog

/// 日志级别（`log-level` 注入值，`core-process` §4）。
///
/// 顺序即 UI 顺序：info → warning → error → debug（debug 只在内核侧生效，
/// 日志窗口的 WS 仍只订阅 `info`，见 `LogStore.streamLevel`）。
enum LogLevelSetting: String, CaseIterable, Codable, Sendable, Identifiable {
    case info
    case warning
    case error
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: "信息"
        case .warning: "警告"
        case .error: "错误"
        case .debug: "调试"
        }
    }

    /// 注入 `log-level` 时用的值
    var cliValue: String { rawValue }
}

/// 应用设置：`settings.json` 的唯一读写者（`docs/01-ARCHITECTURE.md` §3）。
///
/// 边界：
/// - 每次字段变更立即原子写（临时文件 → 0600 → rename），不做「退出时统一保存」
/// - 读取失败 / 损坏：备份为 `settings.corrupt-<时间戳>.json`，按默认值运行并写新文件，日志告警
/// - 写入失败：`lastError` 上报，UI 必须显示，不静默
/// - 非法值（端口越界 / 未知更新间隔）在加载时归一到默认值，不阻塞启动
@MainActor
@Observable
final class SettingsStore {

    /// 端口合法区间：1024–65535（1024 以下需要 root）
    static let portRange = 1024 ... 65535
    /// 「默认更新间隔」可选项（0 = 手动）
    static let autoUpdateOptions = [0, 1, 6, 12, 24]

    /// 落盘结构：新增字段时给默认值，旧文件缺键也能解出来（自定义 `init(from:)`）
    struct Values: Codable, Equatable, Sendable {
        var mixedPort: Int = 7890
        var allowLAN: Bool = false
        /// 关代理是否保留内核（v0.2 起默认保留：关代理后仍能挑节点 / 测速）
        var keepKernelOnProxyOff: Bool = true
        /// 空 = 默认 `mihomo/<内核版本>`（ADR-0006）
        var subscriptionUserAgent: String = ""
        /// 0 = 手动，其余取 `autoUpdateOptions`
        var autoUpdateHours: Int = 0
        var logLevel: LogLevelSetting = .info
        var launchAtLogin: Bool = false
        /// 内核 / geodata 下载源策略（ADR-0012）
        var kernelDownloadMode: KernelDownloadMode = .automatic
        /// 仅 `.custom` 使用：前缀 + 原始 GitHub URL 原样拼接
        var customMirrorPrefix: String = ""

        init() {}

        private enum CodingKeys: String, CodingKey {
            case mixedPort, allowLAN, keepKernelOnProxyOff, subscriptionUserAgent
            case autoUpdateHours, logLevel, launchAtLogin
            case kernelDownloadMode, customMirrorPrefix
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Values()
            mixedPort = try container.decodeIfPresent(Int.self, forKey: .mixedPort) ?? defaults.mixedPort
            allowLAN = try container.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? defaults.allowLAN
            keepKernelOnProxyOff = try container.decodeIfPresent(Bool.self, forKey: .keepKernelOnProxyOff)
                ?? defaults.keepKernelOnProxyOff
            subscriptionUserAgent = try container.decodeIfPresent(String.self, forKey: .subscriptionUserAgent)
                ?? defaults.subscriptionUserAgent
            autoUpdateHours = try container.decodeIfPresent(Int.self, forKey: .autoUpdateHours)
                ?? defaults.autoUpdateHours
            logLevel = try container.decodeIfPresent(LogLevelSetting.self, forKey: .logLevel) ?? defaults.logLevel
            launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
            kernelDownloadMode = try container.decodeIfPresent(
                KernelDownloadMode.self,
                forKey: .kernelDownloadMode
            ) ?? defaults.kernelDownloadMode
            customMirrorPrefix = try container.decodeIfPresent(String.self, forKey: .customMirrorPrefix)
                ?? defaults.customMirrorPrefix
        }
    }

    // MARK: - 对 UI 暴露的状态

    var mixedPort: Int { didSet { persistIfReady() } }
    var allowLAN: Bool { didSet { persistIfReady() } }
    var keepKernelOnProxyOff: Bool { didSet { persistIfReady() } }
    var subscriptionUserAgent: String { didSet { persistIfReady() } }
    var autoUpdateHours: Int { didSet { persistIfReady() } }
    var logLevel: LogLevelSetting { didSet { persistIfReady() } }
    var launchAtLogin: Bool { didSet { persistIfReady() } }
    var kernelDownloadMode: KernelDownloadMode { didSet { persistIfReady() } }
    var customMirrorPrefix: String { didSet { persistIfReady() } }

    /// 最近一次写盘失败的原因（UI 提示用；写成功后清空）
    private(set) var lastError: String?
    /// 启动时读到损坏文件：已备份、已回默认值
    private(set) var corruptBackupURL: URL?

    let fileURL: URL

    private static let logger = Logger(subsystem: "com.clash.app", category: "settings")

    /// 加载期间关闭 didSet 写盘（否则 init 里的每个默认值都会触发一次落盘）
    @ObservationIgnored private var isReady = false

    // MARK: - 初始化

    init(fileURL: URL = AppPaths.settingsURL) {
        self.fileURL = fileURL

        // 显式赋默认值：didSet 在初始化阶段不触发
        let defaults = Values()
        self.mixedPort = defaults.mixedPort
        self.allowLAN = defaults.allowLAN
        self.keepKernelOnProxyOff = defaults.keepKernelOnProxyOff
        self.subscriptionUserAgent = defaults.subscriptionUserAgent
        self.autoUpdateHours = defaults.autoUpdateHours
        self.logLevel = defaults.logLevel
        self.launchAtLogin = defaults.launchAtLogin
        self.kernelDownloadMode = defaults.kernelDownloadMode
        self.customMirrorPrefix = defaults.customMirrorPrefix

        load()
        isReady = true
    }

    // MARK: - 派生

    /// 当前生效的订阅 UA：设置为空时回默认 `mihomo/<内核版本>`（ADR-0006）
    var effectiveSubscriptionUserAgent: String {
        let trimmed = subscriptionUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SubscriptionUserAgent.defaultUserAgent : trimmed
    }

    /// 落盘快照（自检 / 日志用）
    var values: Values {
        var snapshot = Values()
        snapshot.mixedPort = mixedPort
        snapshot.allowLAN = allowLAN
        snapshot.keepKernelOnProxyOff = keepKernelOnProxyOff
        snapshot.subscriptionUserAgent = subscriptionUserAgent
        snapshot.autoUpdateHours = autoUpdateHours
        snapshot.logLevel = logLevel
        snapshot.launchAtLogin = launchAtLogin
        snapshot.kernelDownloadMode = kernelDownloadMode
        snapshot.customMirrorPrefix = customMirrorPrefix
        return snapshot
    }

    // MARK: - 读写

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Self.logger.notice("没有 settings.json，按默认值创建")
            persist()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(Values.self, from: data)
            apply(decoded)
        } catch {
            recoverFromCorruption(error)
        }
    }

    /// 归一非法值后套用（不让一份手改坏的文件把端口写成 22）
    private func apply(_ decoded: Values) {
        let defaults = Values()
        mixedPort = Self.portRange.contains(decoded.mixedPort) ? decoded.mixedPort : defaults.mixedPort
        if !Self.portRange.contains(decoded.mixedPort) {
            Self.logger.error("settings.json 端口 \(decoded.mixedPort) 越界，回默认 \(defaults.mixedPort)")
        }

        allowLAN = decoded.allowLAN
        keepKernelOnProxyOff = decoded.keepKernelOnProxyOff
        subscriptionUserAgent = decoded.subscriptionUserAgent
        autoUpdateHours = Self.autoUpdateOptions.contains(decoded.autoUpdateHours)
            ? decoded.autoUpdateHours
            : defaults.autoUpdateHours
        logLevel = decoded.logLevel
        launchAtLogin = decoded.launchAtLogin
        kernelDownloadMode = decoded.kernelDownloadMode
        customMirrorPrefix = decoded.customMirrorPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 损坏兜底：留证据（`settings.corrupt-*.json`）→ 回默认值 → 重写干净文件
    private func recoverFromCorruption(_ error: Error) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = fileURL.deletingLastPathComponent()
            .appending(path: "settings.corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
            corruptBackupURL = backup
        } catch {
            Self.logger.error("备份损坏的 settings.json 失败：\(error.localizedDescription, privacy: .public)")
        }

        Self.logger.error(
            "settings.json 无法解析，已回默认值：\(error.localizedDescription, privacy: .public)"
        )
        apply(Values())
        persist()
    }

    private func persistIfReady() {
        guard isReady else { return }
        persist()
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(values)
            try AtomicFile.write(data, to: fileURL)
            lastError = nil
        } catch {
            Self.logger.error("写 settings.json 失败：\(error.localizedDescription, privacy: .public)")
            lastError = "设置保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 自检入口

    #if DEBUG
    /// 自检用（`CLASH_SETTINGS_HARNESS`）：从内存快照覆盖，不写盘
    func applyForSelfCheck(_ values: Values) {
        apply(values)
    }
    #endif
}
