import Foundation
import Observation
import OSLog

/// 激活状态的变化：调用方（面板模型）据此决定是否重启 / 停止内核。
enum ProfileActivationChange: Equatable, Sendable {
    /// active 没变
    case none
    /// active 换到了另一条 → 内核若在跑需要重建 runtime 并重启
    case switched
    /// active 被清空（库里已没有配置）→ 内核若在跑需要停止
    case cleared
}

/// 订阅库：`profiles/index.json` 的唯一读写者（`docs/01-ARCHITECTURE.md` §4.1）。
///
/// 边界：
/// - 只存元数据进 `index.json`；配置正文原样落 `profiles/<id>.yaml`，**永不改写**
/// - 文件名一律用 `id`，显示名（含特殊字符）只进索引，不做路径
/// - 入库 / 更新前都跑 `mihomo -t`；失败保留旧 yaml，只写 `lastError` / `lastAttemptAt`
/// - 定时更新只存 `autoUpdateHours` 字段，调度器不在本轮
@MainActor
@Observable
final class ProfileStore {

    // MARK: - 对 UI 暴露的状态

    /// 索引顺序即列表顺序
    private(set) var entries: [ProfileEntry] = []
    /// 同一时刻只有一条 active
    private(set) var activeProfileID: String?

    var activeProfile: ProfileEntry? {
        guard let activeProfileID else { return nil }
        return entries.first { $0.id == activeProfileID }
    }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let indexURL: URL
    @ObservationIgnored private let now: () -> Date

    private static let logger = Logger(subsystem: "com.clash.app", category: "profiles")
    private static let defaultAutoUpdateHours = 24

    // MARK: - 初始化

    /// - Parameters:
    ///   - directory: `profiles/` 目录（自检 harness 用临时目录）
    ///   - now: 注入时钟，测试可固定时间
    init(
        directory: URL = AppPaths.profilesDirectory,
        indexURL: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.indexURL = indexURL ?? directory.appending(path: "index.json")
        self.now = now
        load()
    }

    func yamlURL(for id: String) -> URL {
        directory.appending(path: "\(id).yaml")
    }

    func entry(id: String) -> ProfileEntry? {
        entries.first { $0.id == id }
    }

    // MARK: - 索引读写

    private func load() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("创建 profiles 目录失败：\(error.localizedDescription, privacy: .public)")
        }

        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            entries = []
            activeProfileID = nil
            do {
                try persistIndex()
            } catch {
                Self.logger.error("创建空索引失败：\(error.localizedDescription, privacy: .public)")
            }
            return
        }

        do {
            let index = try ProfileIndexFile.load(from: indexURL)
            entries = index.profiles
            activeProfileID = index.activeProfileID
        } catch {
            // 索引损坏：留证据、按空库运行，绝不覆盖原文件当没事发生
            Self.logger.error("index.json 解析失败：\(error.localizedDescription, privacy: .public)")
            let backup = directory.appending(path: "index.corrupt-\(Int(now().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: indexURL, to: backup)
            entries = []
            activeProfileID = nil
            try? persistIndex()
            return
        }

        // active 指向不存在的条目（手工改过索引）→ 清空，不猜
        if let id = activeProfileID, entry(id: id) == nil {
            Self.logger.error("activeProfileID 指向不存在的条目：\(id, privacy: .public)")
            activeProfileID = nil
            try? persistIndex()
        }
    }

    private func persistIndex() throws {
        let index = ProfileIndex(activeProfileID: activeProfileID, profiles: entries)
        do {
            let data = try ProfileIndexFile.makeEncoder().encode(index)
            try AtomicFile.write(data, to: indexURL)
        } catch {
            Self.logger.error("写 index.json 失败：\(error.localizedDescription, privacy: .public)")
            throw ProfileStoreError.storageFailure
        }
    }

    // MARK: - 导入

    /// 本地 YAML：读 → 解析校验 → `mihomo -t` → 入库（允许同一文件导入多次）
    @discardableResult
    func importFile(at fileURL: URL) async throws -> ProfileEntry {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ProfileStoreError.fileUnreadable
        }
        let text = try decodeText(data)
        try ensureYAMLMapping(text)
        try await ProfileValidator.validate(yamlText: text)

        let id = makeID()
        try writeYAML(data, to: id)

        let timestamp = now()
        let entry = ProfileEntry(
            id: id,
            name: displayName(forFile: fileURL),
            source: ProfileSource(kind: .file, path: fileURL.path),
            updatedAt: timestamp,
            autoUpdateHours: 0,
            lastAttemptAt: timestamp
        )
        entries.append(entry)
        if activeProfileID == nil { activeProfileID = id }
        try persistIndex()

        Self.logger.notice("导入本地配置 id=\(id, privacy: .public)")
        return entry
    }

    /// 订阅 URL：GET（UA 策略 + 422 重试）→ 解析校验 → `mihomo -t` → 入库。
    /// 同一 URL 已存在时原地更新那一条，不新增。
    @discardableResult
    func importURL(_ raw: String) async throws -> ProfileEntry {
        let url = try normalizedURL(raw)

        // 同一 URL 已存在：走更新流程（失败时旧 yaml 保留、lastError 落到那一条）
        if let existing = entries.first(where: {
            $0.source.kind == .url && $0.source.url == url.absoluteString
        }) {
            Self.logger.notice("订阅已存在，按更新处理 id=\(existing.id, privacy: .public)")
            return try await update(id: existing.id)
        }

        let download = try await SubscriptionFetcher.fetch(url: url)
        try ensureYAMLMapping(download.text)
        try await ProfileValidator.validate(yamlText: download.text)

        let id = makeID()
        try writeYAML(download.data, to: id)

        let timestamp = now()
        var entry = ProfileEntry(
            id: id,
            name: download.fileName ?? url.host() ?? "订阅",
            source: ProfileSource(kind: .url, url: url.absoluteString),
            updatedAt: timestamp,
            autoUpdateHours: download.autoUpdateHours ?? Self.defaultAutoUpdateHours,
            lastAttemptAt: timestamp,
            subscriptionInfo: download.subscriptionInfo,
            webPageURL: download.webPageURL
        )
        entry.lastError = nil
        entries.append(entry)
        if activeProfileID == nil { activeProfileID = id }
        try persistIndex()

        Self.logger.notice(
            "导入订阅 id=\(id, privacy: .public) ua=\(download.userAgent, privacy: .public)"
        )
        return entry
    }

    // MARK: - 更新

    /// 更新一条：失败保留旧 yaml，只写 `lastError` / `lastAttemptAt`（架构 §4.1 约束）
    @discardableResult
    func update(id: String) async throws -> ProfileEntry {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.notFound
        }

        var entry = entries[index]
        entry.lastAttemptAt = now()
        entries[index] = entry

        do {
            let data: Data
            var download: SubscriptionDownload?

            switch entry.source.kind {
            case .file:
                guard let path = entry.source.path else { throw ProfileStoreError.sourceMissing }
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ProfileStoreError.sourceMissing
                }
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    throw ProfileStoreError.fileUnreadable
                }
            case .url:
                guard let raw = entry.source.url, let url = URL(string: raw) else {
                    throw ProfileStoreError.invalidURL
                }
                let result = try await SubscriptionFetcher.fetch(url: url)
                data = result.data
                download = result
            }

            let text = try decodeText(data)
            try ensureYAMLMapping(text)
            try await ProfileValidator.validate(yamlText: text)

            // 校验通过才原子替换旧文件
            try writeYAML(data, to: id)

            entry.updatedAt = now()
            entry.lastError = nil
            if let download {
                apply(download, to: &entry)
            }
            entries[index] = entry
            try persistIndex()
            Self.logger.notice("更新成功 id=\(id, privacy: .public)")
            return entry
        } catch {
            let storeError = (error as? ProfileStoreError) ?? .configInvalid(detail: "未知错误")
            entry.lastError = storeError.userMessage
            entries[index] = entry
            try? persistIndex()
            Self.logger.error(
                "更新失败 id=\(id, privacy: .public)：\(storeError.logDescription, privacy: .public)"
            )
            throw storeError
        }
    }

    // MARK: - 切换 / 重命名 / 删除

    @discardableResult
    func activate(id: String) throws -> ProfileActivationChange {
        guard entry(id: id) != nil else { throw ProfileStoreError.notFound }
        guard FileManager.default.fileExists(atPath: yamlURL(for: id).path) else {
            throw ProfileStoreError.sourceMissing
        }
        guard activeProfileID != id else { return .none }

        activeProfileID = id
        try persistIndex()
        Self.logger.notice("切换激活配置 id=\(id, privacy: .public)")
        return .switched
    }

    /// 只改显示名，不动文件名
    func rename(id: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileStoreError.emptyName }
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.notFound
        }
        entries[index].name = trimmed
        try persistIndex()
    }

    /// 删除：active 被删时先切到另一条，没有其它条目则置空（调用方负责停内核）
    @discardableResult
    func delete(id: String) throws -> ProfileActivationChange {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.notFound
        }

        let wasActive = activeProfileID == id
        let fileURL = yamlURL(for: id)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                Self.logger.error(
                    "删除配置文件失败 id=\(id, privacy: .public)：\(error.localizedDescription, privacy: .public)"
                )
                throw ProfileStoreError.storageFailure
            }
        }

        entries.remove(at: index)

        var change: ProfileActivationChange = .none
        if wasActive {
            if let next = entries.first?.id {
                activeProfileID = next
                change = .switched
            } else {
                activeProfileID = nil
                change = .cleared
            }
        }
        try persistIndex()
        Self.logger.notice("删除配置 id=\(id, privacy: .public) change=\(String(describing: change), privacy: .public)")
        return change
    }

    // MARK: - 内部工具

    /// 成功拉取后的索引字段更新：改名不动（重命名是用户的显式操作）
    private func apply(_ download: SubscriptionDownload, to entry: inout ProfileEntry) {
        let timestamp = now()
        entry.updatedAt = timestamp
        entry.lastAttemptAt = timestamp
        entry.subscriptionInfo = download.subscriptionInfo
        entry.webPageURL = download.webPageURL
        // 建议间隔只在服务端给出时覆盖：本地手动条目（0）不被改写成 24
        if let hours = download.autoUpdateHours {
            entry.autoUpdateHours = hours
        }
    }

    private func decodeText(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProfileStoreError.notYAML
        }
        return text
    }

    /// 解析校验：`Yams.load` 顶层必须是字典
    private func ensureYAMLMapping(_ text: String) throws {
        guard SubscriptionFetcher.isYAMLMapping(text) else {
            throw ProfileStoreError.notYAML
        }
    }

    private func normalizedURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host() != nil else {
            throw ProfileStoreError.invalidURL
        }
        return url
    }

    private func writeYAML(_ data: Data, to id: String) throws {
        do {
            try AtomicFile.write(data, to: yamlURL(for: id))
        } catch {
            Self.logger.error("写配置文件失败 id=\(id, privacy: .public)：\(error.localizedDescription, privacy: .public)")
            throw ProfileStoreError.storageFailure
        }
    }

    /// `id` 同时是文件名前缀：只用 UUID 片段，绝不掺显示名
    private func makeID() -> String {
        var candidate = ""
        repeat {
            candidate = "p_" + UUID().uuidString.prefix(8).lowercased()
        } while entries.contains(where: { $0.id == candidate })
            || FileManager.default.fileExists(atPath: yamlURL(for: candidate).path)
        return candidate
    }

    private func displayName(forFile url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "本地配置" : name
    }
}

