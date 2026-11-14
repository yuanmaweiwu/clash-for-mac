import Foundation
import OSLog

/// 一条节点延迟缓存：数值 + 测速时间（`latency-cache.json` 的最小单元）。
struct LatencyCacheEntry: Codable, Sendable, Equatable {
    /// 毫秒；≤ 0 表示上次测速超时（与「没测过」区分开）
    var delay: Int
    var testedAt: Date
}

/// 延迟缓存：`~/Library/Application Support/Clash/latency-cache.json` 的唯一读写者。
///
/// 为什么需要它：`/proxies` 里的 `history` 是内核内存态，App 退出 / 内核重启就没了。
/// 面板的「上次测到多少」属于用户可感知的参数，必须跨重启保留。
///
/// 边界：
/// - 按 `profileID` 分桶：不同订阅的节点同名也不能串数据
/// - 写操作 1s 合并（`scheduleWrite`），退出 / 完整清理前用 `flush()` 落盘
/// - 原子写 + 0600（`AtomicFile`）；文件损坏按空缓存运行，不阻塞启动
/// - 超过 30 天的条目在加载 / 落盘时丢弃
@MainActor
final class LatencyCache {

    /// 进程内单例：ProxyService 写、ProfileStore 删、退出清理 flush 都指向同一份
    static let shared = LatencyCache()

    /// 过期时间：30 天
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private static let logger = Logger(subsystem: "com.clash.app", category: "latency-cache")

    private let fileURL: URL
    private let now: () -> Date
    /// `profileID → 节点名 → 条目`
    private var store: [String: [String: LatencyCacheEntry]] = [:]
    private var pendingWrite: Task<Void, Never>?

    init(fileURL: URL = AppPaths.latencyCacheURL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        load()
    }

    // MARK: - 读取

    /// 某 profile 下某节点的缓存；过期条目按不存在处理
    func entry(profileID: String?, node: String) -> LatencyCacheEntry? {
        guard let profileID, let entry = store[profileID]?[node] else { return nil }
        guard !isExpired(entry) else { return nil }
        return entry
    }

    /// 某 profile 的全部缓存（自检 / 调试用）
    func entries(profileID: String) -> [String: LatencyCacheEntry] {
        (store[profileID] ?? [:]).filter { !isExpired($0.value) }
    }

    // MARK: - 写入

    /// 记录单个节点（单点测速 / `/proxies` 的 history）
    func record(profileID: String?, node: String, delay: Int, testedAt: Date) {
        guard let profileID, !node.isEmpty else { return }

        let entry = LatencyCacheEntry(delay: delay, testedAt: testedAt)
        if store[profileID]?[node] == entry { return }

        store[profileID, default: [:]][node] = entry
        scheduleWrite()
    }

    /// 记录一组节点（批量测速）：同一时刻测的，`testedAt` 共用
    func record(profileID: String?, delays: [String: Int], testedAt: Date) {
        guard let profileID else { return }

        var changed = false
        for (node, delay) in delays where !node.isEmpty {
            let entry = LatencyCacheEntry(delay: delay, testedAt: testedAt)
            if store[profileID]?[node] == entry { continue }
            store[profileID, default: [:]][node] = entry
            changed = true
        }
        if changed { scheduleWrite() }
    }

    /// profile 被删除：立刻清掉该桶并落盘（要求「删订阅后文件里对应条目消失」可立刻验证）
    func removeProfile(_ profileID: String) {
        guard store.removeValue(forKey: profileID) != nil else { return }
        flush()
    }

    /// 完全清理：只清内存，不再写回（调用前目录可能已被删除）
    func discardAll() {
        pendingWrite?.cancel()
        pendingWrite = nil
        store = [:]
    }

    // MARK: - 合并写

    private func scheduleWrite() {
        guard pendingWrite == nil else { return }
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.pendingWrite = nil
            self.writeNow()
        }
    }

    /// 退出 / 删除订阅前调用：把 1s 窗口里的改动同步落盘
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        writeNow()
    }

    private func writeNow() {
        pruneExpiredInMemory()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(store)
            try AtomicFile.write(data, to: fileURL)
        } catch {
            Self.logger.error("写 latency-cache.json 失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 加载与过期

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            store = try decoder.decode([String: [String: LatencyCacheEntry]].self, from: data)
            if pruneExpiredInMemory() {
                // 过期丢弃是内容变化：立即落盘，避免文件里长期留着死数据
                writeNow()
            }
        } catch {
            // 缓存是可再生的：损坏时按空文件运行，不备份、不阻塞启动
            Self.logger.error("latency-cache.json 解析失败，按空缓存运行：\(error.localizedDescription, privacy: .public)")
            store = [:]
        }
    }

    private func isExpired(_ entry: LatencyCacheEntry) -> Bool {
        now().timeIntervalSince(entry.testedAt) > Self.maxAge
    }

    /// - Returns: 是否有条目被丢弃
    @discardableResult
    private func pruneExpiredInMemory() -> Bool {
        var changed = false
        for (profileID, bucket) in store {
            let fresh = bucket.filter { !isExpired($0.value) }
            if fresh.count != bucket.count {
                changed = true
                if fresh.isEmpty {
                    store.removeValue(forKey: profileID)
                } else {
                    store[profileID] = fresh
                }
            }
        }
        return changed
    }
}
