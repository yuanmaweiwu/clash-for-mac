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
/// - 机场的信息节点（到期时间 / 流量用量 …）在 `makeGroup` 里被 `ProxyNodeFilter` 丢掉：
///   只是展示与可选项，不影响内核配置；过滤后没有节点的组整组不出现
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
    /// 被 `GET /rules` 的 `proxy` 引用到的策略组名（以 `/proxies` 的组名为准，§3.4）
    ///
    /// 空集有两种来源：规则一条都没指向策略组（全是 DIRECT / REJECT…），
    /// 或者规则列表还没拉到。用 `hasRuleSnapshot` 区分，UI 据此决定是否启用「生效组」过滤。
    private(set) var effectiveGroupNames: Set<String> = []
    /// 是否成功拿到过规则快照。false 时（内核没有 `/rules` / 请求失败）UI 退回旧的 pin / 第一组行为
    private(set) var hasRuleSnapshot = false

    /// 首屏 / 列表用的策略组（不含 `GLOBAL`），内核配置顺序
    var groups: [ProxyGroupModel] { allGroups.filter { !$0.isGlobal } }

    /// 首屏 / 列表用的 pin 组：主组恒在最前，其余按用户固定的先后（配置顺序兜底）
    var pinnedGroups: [ProxyGroupModel] {
        var result = allGroups.filter { $0.isPinned && !$0.canPin }
        var seen = Set(result.map(\.name))

        for name in pinOrder {
            guard !seen.contains(name),
                  let group = allGroups.first(where: { $0.name == name }),
                  group.isPinned else { continue }
            result.append(group)
            seen.insert(name)
        }

        // 防御：没有登记固定顺序的 pin（预览夹具 / 未来落盘的旧偏好）按配置顺序补在后面
        for group in allGroups where group.isPinned && !seen.contains(group.name) {
            result.append(group)
            seen.insert(group.name)
        }
        return result
    }

    @ObservationIgnored private let kernel: KernelService
    /// active profile 的来源：延迟缓存按 profile 分桶；nil（预览 / 自检）时只用内核内存态
    @ObservationIgnored private let profileStore: ProfileStore?
    /// 内核重启后用来补齐 `history` 的本地缓存
    @ObservationIgnored private let latencyCache: LatencyCache
    @ObservationIgnored private var client: ClashAPIClient?
    @ObservationIgnored private var clientKey: String?
    /// 上一次成功拉 `/proxies` 的内核会话（端口 + secret）。新会话的第一次刷新把缓存值
    /// 当作「上次测速」展示：mihomo 的 URLTest / Fallback 组会在启动时自动做健康检查，
    /// 那些 history 不是用户点的测速，不能覆盖用户上次真正测出来的缓存。
    @ObservationIgnored private var lastRefreshSessionKey: String?
    /// pin 是 UI 偏好：现在只在内存，后续落 `profiles/index.json` 的 `pinnedGroups`
    @ObservationIgnored private var pinnedNames: Set<String> = []
    /// 用户固定的先后（不含主组）；首屏按这个顺序排，主组恒在最前
    @ObservationIgnored private var pinOrder: [String] = []

    init(
        kernel: KernelService,
        profileStore: ProfileStore? = nil,
        latencyCache: LatencyCache = .shared
    ) {
        self.kernel = kernel
        self.profileStore = profileStore
        self.latencyCache = latencyCache
    }

    // MARK: - 读取

    /// 拉 `/proxies` + `/configs`：策略组、选中项、延迟、模式一起对齐。
    ///
    /// 内核 `running` 后调用；并发调用会被合并（`isRefreshing` 守卫）。
    /// - Returns: 是否成功拿到 `/proxies`。调用方据此决定「组消失后回退路由」这类动作。
    @discardableResult
    func refresh() async -> Bool {
        guard !isRefreshing else { return false }
        guard let client = apiClient() else { return false }

        isRefreshing = true
        defer { isRefreshing = false }

        var loaded = false
        // 端口 / secret 变了 = 新内核会话：第一次刷新优先展示本地缓存（标为陈旧）
        let sessionKey = "\(kernel.port ?? -1):\(kernel.secret ?? "")"
        let isNewSession = sessionKey != lastRefreshSessionKey
        do {
            // 规则与代理一起拉：刷新完就能算出「被规则引用」的组，首屏不用等第二次请求
            async let proxyRequest = client.proxies()
            async let ruleRequest = client.rules()
            let snapshot = try await proxyRequest
            let rules = try? await ruleRequest

            // 组名以 `/proxies` 为准：规则的 `proxy` 只是字符串，不做模糊猜测
            if let rules {
                effectiveGroupNames = Self.effectiveGroups(rules: rules, proxies: snapshot)
                hasRuleSnapshot = true
            } else {
                effectiveGroupNames = []
                hasRuleSnapshot = false
            }

            apply(proxies: snapshot, preferCache: isNewSession)
            lastError = nil
            loaded = true
            lastRefreshSessionKey = sessionKey
        } catch {
            lastError = Self.message(for: error)
        }

        // 模式以 `/configs` 为准；拉不到就保留当前值
        if let snapshot = try? await client.configs(), let synced = snapshot.proxyMode {
            mode = synced
        }
        return loaded
    }

    /// 内核停止 / 失败：清空组数据，面板回到空态
    func clear() {
        allGroups = []
        hasLoaded = false
        isRefreshing = false
        isTesting = false
        testingGroup = nil
        effectiveGroupNames = []
        hasRuleSnapshot = false
        mode = .rule
        lastError = nil
        client = nil
        clientKey = nil
        lastRefreshSessionKey = nil
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
        let testedAt = Date()
        for nodeIndex in allGroups[index].nodes.indices {
            let name = allGroups[index].nodes[nodeIndex].name
            guard let delay = delays[name] else { continue }
            // 本次没测到的条目保留原值；测到 0 视为超时（与「没测过」区分开）
            allGroups[index].nodes[nodeIndex].delayState = delay > 0 ? .ok(delay) : .timeout
            allGroups[index].nodes[nodeIndex].isStale = false
            allGroups[index].nodes[nodeIndex].lastTestedAt = testedAt
        }
        allGroups[index].delay = allGroups[index].nodes.compactMap(\.delay).min()

        latencyCache.record(profileID: profileStore?.activeProfileID, delays: delays, testedAt: testedAt)
    }

    /// 单点测速：结果同时写回内存与延迟缓存（当前 UI 只有批量入口，方法保留给后续单点操作）
    func testNode(group: String, nodeID: String) async {
        guard !isTesting, testingGroup == nil else { return }
        guard allGroups.contains(where: { $0.name == group }),
              let client = apiClient() else { return }

        isTesting = true
        testingGroup = group
        defer {
            isTesting = false
            testingGroup = nil
        }

        do {
            let delay = try await client.testDelay(
                proxy: nodeID,
                timeout: Self.testTimeoutMilliseconds,
                url: Self.testURL
            )
            guard let current = allGroups.firstIndex(where: { $0.name == group }),
                  let currentIndex = allGroups[current].nodes.firstIndex(where: { $0.name == nodeID }) else {
                return
            }
            let testedAt = Date()
            allGroups[current].nodes[currentIndex].delayState = delay > 0 ? .ok(delay) : .timeout
            allGroups[current].nodes[currentIndex].isStale = false
            allGroups[current].nodes[currentIndex].lastTestedAt = testedAt
            allGroups[current].delay = allGroups[current].nodes.compactMap(\.delay).min()
            latencyCache.record(
                profileID: profileStore?.activeProfileID,
                node: nodeID,
                delay: delay,
                testedAt: testedAt
            )
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// `/proxies` 里带 `history` 的条目（含策略组自身的测速历史）写入缓存。
    ///
    /// 用内核给的 `history.time` 作为测速时间；老版本没有 time 就退回本次拉取时间。
    /// - Parameter skipping: 新会话首帧用缓存展示的节点；它们的 history 可能来自内核
    ///   启动时的自动健康检查，不能覆盖用户上次主动测出的缓存值。
    private func recordHistory(in proxies: [String: ProxyEntry], skipping: Set<String> = []) {
        guard let profileID = profileStore?.activeProfileID else { return }
        let fallback = Date()
        for (name, entry) in proxies where !skipping.contains(name) {
            guard let last = entry.history?.last else { continue }
            latencyCache.record(
                profileID: profileID,
                node: name,
                delay: last.delay,
                testedAt: last.time ?? fallback
            )
        }
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
        pinOrder.removeAll { $0 == group }
        if pinned {
            pinnedNames.insert(group)
            pinOrder.append(group)
        } else {
            pinnedNames.remove(group)
        }
    }

    // MARK: - 映射

    private func apply(proxies: [String: ProxyEntry], preferCache: Bool) {
        let orderedNames = Self.orderedGroupNames(in: proxies)

        var built = orderedNames.compactMap { name -> ProxyGroupModel? in
            guard let entry = proxies[name] else { return nil }
            return makeGroup(name: name, entry: entry, proxies: proxies, preferCache: preferCache)
        }

        // GLOBAL 只进「全部策略组」；被过滤空的组不再作为条目出现
        if let global = proxies["GLOBAL"], global.isGroup {
            let droppedGroups = Set(orderedNames).subtracting(built.map(\.name))
            if let group = makeGroup(
                name: "GLOBAL",
                entry: global,
                proxies: proxies,
                excluding: droppedGroups,
                preferCache: preferCache,
                isGlobal: true
            ) {
                built.append(group)
            }
        }

        // §3.4：主组 = 过滤后仍存活的第一个 `select` 组（默认 pin、不可取消）
        let mainGroupName = built.first { !$0.isGlobal && $0.type == "Selector" }?.name
            ?? built.first { !$0.isGlobal }?.name
        for index in built.indices where !built[index].isGlobal {
            let isMain = built[index].name == mainGroupName
            built[index].isPinned = isMain || pinnedNames.contains(built[index].name)
            built[index].canPin = !isMain
        }

        allGroups = built
        hasLoaded = true

        // `/proxies` 里带 history 的节点写缓存；新会话首帧展示的缓存值不覆盖，
        // 否则内核启动时 URLTest / Fallback 的自动健康检查会把用户上次测速结果冲掉
        let staleNames = Set(built.flatMap { group in
            group.nodes.filter(\.isStale).map(\.name)
        })
        recordHistory(in: proxies, skipping: preferCache ? staleNames : [])
    }

    /// 单组的映射；`nil` = 过滤掉信息节点后没有任何可选项（整组不显示，避免空卡）
    private func makeGroup(
        name: String,
        entry: ProxyEntry,
        proxies: [String: ProxyEntry],
        excluding excludedNames: Set<String> = [],
        preferCache: Bool = false,
        isGlobal: Bool = false
    ) -> ProxyGroupModel? {
        let nodes = (entry.all ?? []).compactMap { nodeName -> ProxyNodeModel? in
            guard let node = proxies[nodeName], !excludedNames.contains(nodeName) else { return nil }
            // 机场塞的信息节点（到期时间 / 流量用量 / 官网…）：只能展示，绝不能可选
            guard !ProxyNodeFilter.isInfoNode(nodeName) else { return nil }

            // 内核本次启动的 `history` 是内存态：没有就用上次落盘的缓存，并标成陈旧。
            // 新会话首帧（`preferCache`）即使 history 已经出现，也先展示用户上次的测速结果：
            // URLTest / Fallback 组启动时的自动健康检查不是用户主动测的。
            var delayState = node.delayState
            var isStale = false
            var lastTestedAt: Date?
            var hasHistory = true
            if case .unknown = delayState { hasHistory = false }

            if preferCache || !hasHistory,
               let cached = latencyCache.entry(profileID: profileStore?.activeProfileID, node: nodeName) {
                delayState = cached.delay > 0 ? .ok(cached.delay) : .timeout
                isStale = true
                lastTestedAt = cached.testedAt
            }

            return ProxyNodeModel(
                name: nodeName,
                type: node.type ?? "",
                isGroup: node.isGroup,
                delayState: delayState,
                isAvailable: node.alive ?? true,
                isStale: isStale,
                lastTestedAt: lastTestedAt
            )
        }
        guard !nodes.isEmpty else { return nil }

        // `now` 指向被过滤项（或已经不存在的条目）→ 视为「无有效选中」，卡片首行退化为延迟最低的可用节点
        let now = entry.now.flatMap { name -> String? in
            nodes.contains { $0.name == name } ? name : nil
        }

        return ProxyGroupModel(
            name: name,
            type: entry.type ?? "",
            now: now,
            nodes: nodes,
            delay: entry.lastDelay,
            isPinned: false,
            canPin: !isGlobal,
            isGlobal: isGlobal
        )
    }

    /// 规则目标里的内置策略：不是策略组，永远不算「生效组」
    private static let builtInRuleTargets: Set<String> = ["direct", "reject", "reject-drop", "pass", "compatible"]

    /// 从规则快照里收集被引用的策略组名（§3.4）。
    ///
    /// - 只认 `/proxies` 里真实存在的组名：规则目标是节点名 / 内置策略时自然落空
    /// - 匹配前双方都去掉首尾与内部空白并转小写，避免配置里「香港 01」与规则里「香港01」这类写法差异
    /// - `GLOBAL` 是模式容器，不是规则目标，排除
    private static func effectiveGroups(
        rules: [RuleEntry],
        proxies: [String: ProxyEntry]
    ) -> Set<String> {
        var actualNameByKey: [String: String] = [:]
        for (name, entry) in proxies where entry.isGroup && name != "GLOBAL" {
            actualNameByKey[groupKey(name)] = name
        }

        var names: Set<String> = []
        for rule in rules {
            let key = groupKey(rule.proxy)
            guard !builtInRuleTargets.contains(key) else { continue }
            if let name = actualNameByKey[key] { names.insert(name) }
        }
        return names
    }

    private static func groupKey(_ name: String) -> String {
        String(name.filter { !$0.isWhitespace }).lowercased()
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
        func node(_ name: String, _ state: ProxyDelayState) -> ProxyNodeModel {
            ProxyNodeModel(name: name, type: "Shadowsocks", isGroup: false, delayState: state, isAvailable: true)
        }

        allGroups = [
            ProxyGroupModel(
                name: "节点选择",
                type: "Selector",
                now: "香港 01",
                nodes: [
                    node("香港 01", .ok(32)),
                    node("日本 02", .ok(88)),
                    node("美国 03", .unknown),
                    node("新加坡 04", .ok(64)),
                    node("台湾 05", .ok(41)),
                    node("韩国 06", .ok(95)),
                    node("德国 07", .ok(210)),
                    node("英国 08", .ok(245)),
                    node("澳洲 09", .ok(312))
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
                    node("日本 02", .ok(88)),
                    node("香港 01", .ok(32)),
                    node("新加坡 04", .ok(64)),
                    node("台湾 05", .ok(41)),
                    node("美国 03", .unknown),
                    node("韩国 06", .ok(95))
                ],
                delay: 32,
                isPinned: false,
                canPin: true,
                isGlobal: false
            )
        ]
        effectiveGroupNames = ["节点选择"]
        hasRuleSnapshot = true
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
