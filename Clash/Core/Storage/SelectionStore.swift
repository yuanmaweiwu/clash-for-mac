import Foundation
import Observation
import OSLog

/// 用户手动选中的节点（组名 → 节点名），落盘 `selection.json`。
///
/// 为什么内核已有 `profile.store-selected: true` 还要另存一份：
/// - 本地内核与 TUN 内核是两个 `-d` 目录（`~/Library/Application Support/Clash/kernel`
///   与 `/Library/Application Support/ClashHelper`），各自的 `cache.db` 不共享；
/// - 订阅更新后节点名变化，内核会静默回退到组内第一个节点，没有任何提示。
///
/// 本类只记录「用户主动点击」的结果；启动恢复 / 切订阅后的回填**不写**，
/// 避免把内核的默认选择误当成用户意图。
@MainActor
@Observable
final class SelectionStore {

    /// 落盘结构：`{"groups": {"节点选择": "香港 | 09"}}`
    struct Values: Codable, Equatable, Sendable {
        var groups: [String: String] = [:]
    }

    /// 当前保存的组 → 节点（已剔除空值）
    private(set) var groups: [String: String] = [:]
    /// 最近一次写盘失败的原因（UI 提示用；写成功后清空）
    private(set) var lastError: String?

    let fileURL: URL

    private static let logger = Logger(subsystem: "com.clash.app", category: "selection")

    init(fileURL: URL = AppPaths.selectionURL) {
        self.fileURL = fileURL
        load()
    }

    var isEmpty: Bool { groups.isEmpty }

    func node(for group: String) -> String? { groups[group] }

    // MARK: - 写入

    /// 用户手动选中成功后记录。同值不重复落盘。
    func record(group: String, node: String) {
        let group = group.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = node.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !group.isEmpty, !node.isEmpty, groups[group] != node else { return }
        groups[group] = node
        persist()
    }

    /// 完全清理时与其它用户数据一起清空（文件本身由清理流程移进废纸篓）
    func clearInMemory() {
        groups = [:]
        lastError = nil
    }

    // MARK: - 读写

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(Values.self, from: data)
            groups = decoded.groups.filter { key, value in
                !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            lastError = nil
        } catch {
            // 选择记录是可再生的：读坏不阻塞启动，也不覆盖用户文件（下一次 record 才重写）
            Self.logger.error("selection.json 无法解析，按空记录继续：\(error.localizedDescription, privacy: .public)")
            groups = [:]
            lastError = "节点选择记录损坏，已按默认继续"
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(Values(groups: groups))
            try AtomicFile.write(data, to: fileURL)
            lastError = nil
        } catch {
            Self.logger.error("写 selection.json 失败：\(error.localizedDescription, privacy: .public)")
            lastError = "节点选择保存失败：\(error.localizedDescription)"
        }
    }
}
