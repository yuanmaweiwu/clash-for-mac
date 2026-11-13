import Foundation
import Observation

/// 连接列表的数据源：`GET /connections` 快照 + 单条 / 全部关闭（`core-process` §5）。
///
/// 边界：
/// - 面板打开期间每 2s 拉一次快照（`startPolling` / `stopPolling` 由二级页生命周期驱动）；
///   面板收起就停，面板是浮层、没有常驻理由
/// - 关连接是乐观更新：先本地移除，DELETE 失败按原位置回滚并写 `lastError`
/// - 内核停止 / 失败：清空列表，错误文案一并清掉
/// - TODO(v1.0): 换 WS `/connections`（内核推送增量），届时删掉这里的轮询与 `pollTask`
@MainActor
@Observable
final class ConnectionService {

    /// 面板打开期间的轮询间隔（`/connections` 没有增量语义，先整表刷新）
    static let pollInterval: Duration = .seconds(2)

    private(set) var entries: [ConnectionEntry] = []
    /// 拉取中：防止轮询与手动刷新叠在一起
    private(set) var isRefreshing = false
    /// 最近一次拉取 / 关闭的失败文案；成功后清空
    private(set) var lastError: String?

    var count: Int { entries.count }

    /// 当前列表的累计上传 / 下载字节（按条目求和）
    var totalUp: Int64 { entries.reduce(0) { $0 + $1.upload } }
    var totalDown: Int64 { entries.reduce(0) { $0 + $1.download } }

    @ObservationIgnored private let kernel: KernelService
    @ObservationIgnored private var client: ClashAPIClient?
    @ObservationIgnored private var clientKey: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(kernel: KernelService) {
        self.kernel = kernel
    }

    // MARK: - 轮询

    /// 面板出现：立刻拉一次，之后每 2s 一次；重复调用幂等
    func startPolling() {
        guard pollTask == nil else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                guard !Task.isCancelled else { return }
                do {
                    try await Task.sleep(for: Self.pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// 面板消失：停轮询（保留最后一帧数据，下次打开先刷新）
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - 读取

    /// 拉一次快照；内核没跑就清空（不编造旧数据）
    func refresh() async {
        guard !isRefreshing else { return }
        guard kernel.phase == .running, let client = apiClient() else {
            clear()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            entries = try await client.connections()
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// 内核停止 / 失败：清空列表与错误，避免下次启动显示上一次会话的连接
    func clear() {
        entries = []
        isRefreshing = false
        lastError = nil
        client = nil
        clientKey = nil
    }

    // MARK: - 关闭

    /// 关闭单条：先本地移除（行立刻消失），失败按原位置插回并写 `lastError`
    func close(id: String) async {
        guard let client = apiClient() else { return }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }

        let removed = entries.remove(at: index)
        do {
            try await client.closeConnection(id: id)
            // DELETE 期间可能被轮询插回来，成功后按 id 再清一次
            entries.removeAll { $0.id == id }
            lastError = nil
        } catch {
            guard !entries.contains(where: { $0.id == id }) else {
                lastError = Self.message(for: error)
                return
            }
            entries.insert(removed, at: min(index, entries.count))
            lastError = Self.message(for: error)
        }
    }

    /// 关闭全部：先清空（面板立刻进空态），失败整表回滚
    func closeAll() async {
        guard let client = apiClient(), !entries.isEmpty else { return }

        let snapshot = entries
        entries = []
        do {
            try await client.closeAllConnections()
            // 轮询可能带回了 DELETE 之前的一帧，成功后统一清空
            entries.removeAll()
            lastError = nil
        } catch {
            entries = snapshot
            lastError = Self.message(for: error)
        }
    }

    // MARK: - 客户端 / 错误

    /// 端口或 secret 变了就重建客户端（`core-process` §5）
    private func apiClient() -> ClashAPIClient? {
        guard let port = kernel.port, let secret = kernel.secret else { return nil }
        let key = "\(port):\(secret)"
        if let client, clientKey == key { return client }

        let fresh = ClashAPIClient(port: port, secret: secret)
        client = fresh
        clientKey = key
        return fresh
    }

    private static func message(for error: Error) -> String {
        guard let apiError = error as? ClashAPIClient.APIError else {
            return "操作失败，请稍后重试"
        }
        return apiError.userMessage
    }
}
