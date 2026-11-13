import Foundation
import Observation

/// 策略组 / 节点 / 模式的数据源（`docs/01-ARCHITECTURE.md` §5）。
///
/// 把 `GET /proxies` 映射成面板模型，并承载「选节点 / 批量测速 / 切模式」三个写操作；
/// UI 只读本类，不直接碰 `ClashAPIClient`。
///
/// 边界：
/// - `GLOBAL` 是内核合成的容器组，放进 `allGroups` 供「全部策略组」二级页，但默认不 pin、不进首屏
/// - 组内嵌套组（组的 `all` 里出现另一个组名）按普通条目处理：选中它就是让父组指向子组
@MainActor
@Observable
final class ProxyService {

    /// 组测速的探测地址与内核侧超时（`core-process` §5）
    static let testURL = "http://www.gstatic.com/generate_204"
    static let testTimeoutMilliseconds = 2000

    /// 全部策略组（含 `GLOBAL`），内核配置顺序
    private(set) var allGroups: [ProxyGroupModel] = []
    private(set) var isRefreshing = false
    private(set) var isTesting = false
    /// 最近一次写操作 / 拉取的失败文案；成功后清空
    private(set) var lastError: String?
    private(set) var mode: ProxyMode = .rule
    /// 是否成功从内核拿到过数据（空态文案据此区分「没配置」与「配置里没有策略组」）
    private(set) var hasLoaded = false
    /// 正在测速的组（互斥用）
    private(set) var testingGroup: String?

    /// 首屏 / 列表用的策略组（不含 `GLOBAL`），内核配置顺序
    var groups: [ProxyGroupModel] { allGroups.filter { !$0.isGlobal } }
    var pinnedGroups: [ProxyGroupModel] { allGroups.filter(\.isPinned) }

    @ObservationIgnored private let kernel: KernelService
    @ObservationIgnored private var client: ClashAPIClient?
    @ObservationIgnored private var clientKey: String?
    /// pin 是 UI 偏好：现在只在内存，后续落 `profiles/index.json` 的 `pinnedGroups`
    @ObservationIgnored private var pinnedNames: Set<String> = []

    init(kernel: KernelService) {
        self.kernel = kernel
    }

    // MARK: - 读取

    /// 拉 `/proxies` + `/configs`：策略组、选中项、延迟、模式一起对齐。
    ///
    /// 内核 `running` 后调用；并发调用会被合并（`isRefreshing` 守卫）。
    func refresh() async {
        guard !isRefreshing else { return }
        guard let client = apiClient() else {
            clear()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            apply(proxies: try await client.proxies())
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }

        // 模式以 `/configs` 为准；拉不到就保留当前值
        if let snapshot = try? await client.configs(), let synced = snapshot.proxyMode {
            mode = synced
        }
    }

    /// 内核停止 / 失败：清空组数据，面板回到空态
    func clear() {
        allGroups = []
        hasLoaded = false
        isRefreshing = false
        isTesting = false
        testingGroup = nil
        mode = .rule
        lastError = nil
        client = nil
        clientKey = nil
    }

    // MARK: - 选节点

    /// 切换组内节点：乐观更新 `now`，请求失败回滚
    func selectNode(group: String, node: String) async {
        guard let index = allGroups.firstIndex(where: { $0.name == group }) else { return }
        let previous = allGroups[index].now
        guard previous != node else { return }
        guard let client = apiClient() else { return }

        allGroups[index].now = node
        do {
            try await client.selectProxy(group: group, name: node)
            lastError = nil
        } catch {
            if let rollback = allGroups.firstIndex(where: { $0.name == group }) {
                allGroups[rollback].now = previous
            }
            lastError = Self.message(for: error)
        }
    }

    // MARK: - 测速

    /// 批量测速：互斥（测速中直接忽略），结果写回节点延迟
    func testAll(group: String) async {
        guard !isTesting, testingGroup == nil else { return }
        guard allGroups.contains(where: { $0.name == group }) else { return }
        guard let client = apiClient() else { return }

        isTesting = true
        testingGroup = group
        defer {
            isTesting = false
            testingGroup = nil
        }

        do {
            let delays = try await client.testGroupDelay(
                group: group,
                timeout: Self.testTimeoutMilliseconds,
                url: Self.testURL
            )
            apply(delays: delays, group: group)
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }
    }

    private func apply(delays: [String: Int], group: String) {
        guard let index = allGroups.firstIndex(where: { $0.name == group }) else { return }
        for nodeIndex in allGroups[index].nodes.indices {
            let name = allGroups[index].nodes[nodeIndex].name
            guard let delay = delays[name] else { continue }
            // 本次没测到的条目保留原值；测到 0 视为超时
            allGroups[index].nodes[nodeIndex].delay = delay > 0 ? delay : nil
        }
        allGroups[index].delay = allGroups[index].nodes.compactMap(\.delay).min()
    }

    // MARK: - 模式

    /// 切模式：`PATCH /configs` 成功后生效，失败回滚并留下 `lastError`
    func setMode(_ newMode: ProxyMode) async {
        guard newMode != mode else { return }
        guard let client = apiClient() else {
            lastError = "内核未运行"
            return
        }

        let previous = mode
        mode = newMode
        do {
            try await client.patchMode(newMode.rawValue)
            lastError = nil
        } catch {
            mode = previous
            lastError = Self.message(for: error)
        }
    }

    // MARK: - pin

    func togglePin(group: String) {
        guard let index = allGroups.firstIndex(where: { $0.name == group }),
              allGroups[index].canPin else { return }

        let pinned = !allGroups[index].isPinned
        allGroups[index].isPinned = pinned
        if pinned {
            pinnedNames.insert(group)
        } else {
            pinnedNames.remove(group)
        }
    }

    // MARK: - 映射

    private func apply(proxies: [String: ProxyEntry]) {
        let orderedNames = Self.orderedGroupNames(in: proxies)
        // §3.4：主组 = 配置里第一个 `select` 组，默认 pin、不可取消
        let mainGroupName = orderedNames.first { proxies[$0]?.type == "Selector" } ?? orderedNames.first

        var built = orderedNames.compactMap { name -> ProxyGroupModel? in
            guard let entry = proxies[name] else { return nil }
            return makeGroup(name: name, entry: entry, proxies: proxies, mainGroupName: mainGroupName)
        }

        // GLOBAL 只进「全部策略组」
        if let global = proxies["GLOBAL"], global.isGroup {
            built.append(makeGroup(name: "GLOBAL", entry: global, proxies: proxies, mainGroupName: nil, isGlobal: true))
        }

        allGroups = built
        hasLoaded = true
    }

    private func makeGroup(
        name: String,
        entry: ProxyEntry,
        proxies: [String: ProxyEntry],
        mainGroupName: String?,
        isGlobal: Bool = false
    ) -> ProxyGroupModel {
        let nodes = (entry.all ?? []).compactMap { nodeName -> ProxyNodeModel? in
            guard let node = proxies[nodeName] else { return nil }
            return ProxyNodeModel(
                name: nodeName,
                type: node.type ?? "",
                isGroup: node.isGroup,
                delay: node.lastDelay,
                isAvailable: node.alive ?? true
            )
        }

        let isMainGroup = !isGlobal && name == mainGroupName
        return ProxyGroupModel(
            name: name,
            type: entry.type ?? "",
            now: entry.now,
            nodes: nodes,
            delay: entry.lastDelay,
            isPinned: !isGlobal && (isMainGroup || pinnedNames.contains(name)),
            canPin: !isGlobal && !isMainGroup,
            isGlobal: isGlobal
        )
    }

    /// 组顺序：`/proxies` 是字典（键无顺序），用 `GLOBAL.all` 还原内核的配置顺序，兜底按名字排序
    private static func orderedGroupNames(in proxies: [String: ProxyEntry]) -> [String] {
        var ordered: [String] = []

        for name in proxies["GLOBAL"]?.all ?? [] where name != "GLOBAL" {
            guard proxies[name]?.isGroup == true, !ordered.contains(name) else { continue }
            ordered.append(name)
        }

        let remaining = proxies
            .compactMap { name, entry in entry.isGroup && name != "GLOBAL" ? name : nil }
            .sorted()
        for name in remaining where !ordered.contains(name) {
            ordered.append(name)
        }
        return ordered
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

    #if DEBUG
    /// Preview 夹具：不启动内核，摆出两张同结构的卡（仅设计预览用，不参与运行）
    func applyPreviewFixture() {
        func node(_ name: String, _ delay: Int?) -> ProxyNodeModel {
            ProxyNodeModel(name: name, type: "Shadowsocks", isGroup: false, delay: delay, isAvailable: true)
        }

        allGroups = [
            ProxyGroupModel(
                name: "节点选择",
                type: "Selector",
                now: "香港 01",
                nodes: [
                    node("香港 01", 32),
                    node("日本 02", 88),
                    node("美国 03", nil),
                    node("新加坡 04", 64),
                    node("台湾 05", 41),
                    node("韩国 06", 95),
                    node("德国 07", 210),
                    node("英国 08", 245),
                    node("澳洲 09", 312)
                ],
                delay: 32,
                isPinned: true,
                canPin: false,
                isGlobal: false
            ),
            ProxyGroupModel(
                name: "自动选择",
                type: "URLTest",
                now: "香港 01",
                nodes: [
                    node("日本 02", 88),
                    node("香港 01", 32),
                    node("新加坡 04", 64),
                    node("台湾 05", 41),
                    node("美国 03", nil),
                    node("韩国 06", 95)
                ],
                delay: 32,
                isPinned: false,
                canPin: true,
                isGlobal: false
            )
        ]
        hasLoaded = true
    }

    /// Preview 夹具：把所有可 pin 的组都 pin 上（摆双卡形态）
    func previewPinAllGroups() {
        for index in allGroups.indices where allGroups[index].canPin {
            allGroups[index].isPinned = true
        }
    }
    #endif
}
