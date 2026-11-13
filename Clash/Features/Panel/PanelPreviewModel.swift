// TODO(v0.2): 订阅库 / 流量仍是本地假数据；内核生命周期、策略组与模式已接真
import CoreGraphics
import Foundation
import Observation

/// v0.1 面板模型：**内核与策略组是真的**（`KernelService` / `ProxyService`），订阅与流量仍是本地假数据。
///
/// 视图只和本模型打交道；内核状态、策略组、节点、模式都在本模型里转发一次，
/// 避免 View 直接依赖 `KernelService` / `ProxyService`。
///
/// ## 仍是假数据的字段（下一轮接真实订阅 / 流量）
///
/// - `subscriptions` / `activeSubscriptionID` / `updatingSubscriptionID`：订阅库（`makeSubscriptions()`）
/// - 订阅更新 / 重命名 / 删除：只在内存里改，不读写任何文件
/// - `updatedText` / `refreshProfile()`：底栏「N 分钟前更新」（v0.1 底栏固定显示「未导入配置」）
/// - 流量速率与曲线：v0.1 没接管流量，恒走空态
///
/// **已经是真的**：
/// - 内核生命周期（`phase` / `lastError`），来自 `KernelService`
/// - 策略组 / 节点 / 延迟 / 选中项 / 模式，来自 `ProxyService`（`GET /proxies`、`GET /configs`）
/// - 选节点（`PUT /proxies/{group}`）、批量测速（`GET /group/{name}/delay`）、切模式（`PATCH /configs`）
///
/// **明确不做假的**：系统代理与 TUN（ADR-0007 决定 v0.1 不接管流量），
/// 因此没有流量数字、没有波形、没有 TUN 开关态。
@MainActor
@Observable
final class PanelPreviewModel {

    // MARK: 内核 / 系统代理 / 模式 / TUN

    /// 真实内核生命周期；`phase` / `errorMessage` 都从这里转发
    @ObservationIgnored private let kernel: KernelService
    /// 真实策略组 / 节点 / 模式
    @ObservationIgnored private let proxies: ProxyService

    /// v0.1 没有系统代理（ADR-0007）：恒为 `false`，且刻意声明成 `let`。
    ///
    /// 没有写入口 ⇒ `status` 在 `running` 时只会是「已就绪 / 直连」，
    /// 「代理中」在 v0.1 结构上不可达。v0.2 接入系统代理后再改成可写状态。
    let systemProxyOn = false

    /// 内核当前模式（`GET /configs` 为准）
    var mode: ProxyMode { proxies.mode }

    /// 内核启动失败时的用户文案；真实来源是 `KernelError.userMessage`
    var errorMessage: String? { kernel.lastError?.userMessage }

    /// 是否展示 banner（派生，不再手动置位）
    var showsErrorBanner: Bool { errorMessage != nil }

    // MARK: 导航（首层 / 二级）

    var route: PanelRoute = .root

    // MARK: 分组与订阅

    /// 首屏 / 列表用的策略组（不含 `GLOBAL`），来自内核
    var groups: [ProxyGroupModel] { proxies.groups }
    /// 全部策略组（含 `GLOBAL`），供「全部策略组」二级页
    var allGroups: [ProxyGroupModel] { proxies.allGroups }
    /// 当前操作的组：「全部策略组」的高亮；没操作过时默认第一个（主组）
    var activeGroupID: String? { selectedGroupID ?? groups.first?.name }
    @ObservationIgnored private var selectedGroupID: String?

    var subscriptions: [SubscriptionProfile]
    var activeSubscriptionID: UUID?
    private(set) var updatingSubscriptionID: UUID?
    private(set) var subscriptionNotice: String?
    private(set) var speedNotice: String?
    /// 测速完成后的「刚刚更新」短暂提示
    private(set) var speedResultFlash = false

    /// 底栏「N 分钟前更新」：仍是假数据，且 v0.1 不展示（底栏固定显示「未导入配置」）
    var updatedText = "2 分钟前更新"
    private(set) var downRate = DemoTraffic.initialDownRate
    private(set) var upRate = DemoTraffic.initialUpRate
    private(set) var downSeries = DemoTraffic.downSeries
    private(set) var upSeries = DemoTraffic.upSeries

    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var speedTask: Task<Void, Never>?
    @ObservationIgnored private var speedNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var speedFlashTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var modeTask: Task<Void, Never>?
    @ObservationIgnored private var proxyRefreshTask: Task<Void, Never>?

    init(kernel: KernelService = KernelService()) {
        self.kernel = kernel
        self.proxies = ProxyService(kernel: kernel)
        let profiles = Self.makeSubscriptions()
        subscriptions = profiles
        activeSubscriptionID = profiles.first?.id

        // 内核一就绪就拉真实策略组；停止 / 失败即清空
        kernel.onPhaseChange = { [weak self] phase in
            self?.handleKernelPhase(phase)
        }

        startTrafficFeed()
    }

    // MARK: - 派生状态

    /// 内核相位（转发 `KernelService`，只读）
    var phase: KernelPhase { kernel.phase }

    /// 内核版本（`/version` 的 `version` 字段）；未运行时为 nil
    var kernelVersion: String? { kernel.kernelVersion }

    /// 启动 / 停止过程中：连接磁贴不可再点
    var isKernelBusy: Bool { kernel.isTransitioning }

    /// 状态条文案（§3.3）：v0.1 只有「未运行 / 启动中 / 已就绪 / 直连 / 启动失败」。
    ///
    /// `systemProxyOn` 恒为 `false`，所以 `running` 只会是「已就绪」或「直连」；
    /// 「代理中」要等 v0.2 系统代理接上之后才可能出现。
    var status: DemoStatus {
        switch phase {
        case .stopped:
            return .idle
        case .starting:
            return .starting
        case .failed:
            return .failed
        case .running:
            guard systemProxyOn else { return mode == .direct ? .direct : .ready }
            return mode == .direct ? .direct : .proxying
        }
    }

    /// 是否真的有流量可以展示：v0.1 没接管流量的通道，一律不显示数字与波形（§4.5 空态）。
    var showsLiveTraffic: Bool { systemProxyOn && status.hasLiveRates }

    var downRateText: String { DemoTraffic.format(rate: downRate) }
    var upRateText: String { DemoTraffic.format(rate: upRate) }

    var pinnedGroups: [ProxyGroupModel] { proxies.pinnedGroups }
    var pinnedGroupIDs: Set<String> { Set(pinnedGroups.map(\.id)) }

    /// 空态文案：有配置且内核给出过数据、但一个策略组都没有 → 「当前配置没有策略组」
    var emptyGroupTitle: String {
        proxies.hasLoaded && kernel.hasProfile ? "当前配置没有策略组" : "还没有配置"
    }

    var activeSubscription: SubscriptionProfile? {
        guard let id = activeSubscriptionID else { return nil }
        return subscriptions.first { $0.id == id }
    }

    var subscriptionTileSubtitle: String? {
        guard let active = activeSubscription else { return nil }
        return active.updateFailed ? "\(active.name) · 更新失败" : active.name
    }

    var subscriptionBadgeCount: Int { subscriptions.count }

    // MARK: - 内核相位

    private func handleKernelPhase(_ phase: KernelPhase) {
        switch phase {
        case .running:
            proxyRefreshTask?.cancel()
            proxyRefreshTask = Task { [weak self] in
                await self?.proxies.refresh()
            }
        case .stopped, .failed:
            // 组数据作废：二级页的目标可能已经不在了，先回首层，避免空白面板
            proxyRefreshTask?.cancel()
            proxies.clear()
            selectedGroupID = nil
            route = .root
        case .starting:
            break
        }
    }

    // MARK: - 连接磁贴

    /// 未运行 → 启动内核；运行中 → 停止内核；启动/停止过程中忽略点击
    func toggleConnection() {
        guard !kernel.isTransitioning else { return }
        switch phase {
        case .starting:
            return
        case .stopped, .failed:
            startKernel()
        case .running:
            stopKernel()
        }
    }

    private func startKernel() {
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            guard let self else { return }
            await self.kernel.start()
            // 就绪后由 `onPhaseChange` 触发 `proxies.refresh()`
        }
    }

    private func stopKernel() {
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            await self?.kernel.stop()
        }
    }

    // MARK: - 代理模式

    /// 分段点击 → `PATCH /configs`；失败由 service 回滚
    func selectMode(_ newMode: ProxyMode) {
        guard proxies.mode != newMode else { return }
        modeTask?.cancel()
        modeTask = Task { [weak self] in
            await self?.proxies.setMode(newMode)
        }
    }

    // MARK: - TUN 磁贴
    //
    // v0.1 没有 helper / root 权限（ADR-0007），TUN 不可用，也不做假开关：
    // 磁贴恒为灰态「需要管理员组件」，点击只解释原因（见 `ControlGridView`）。

    // MARK: - 导航

    func openAllGroups() { route = .allGroups }
    func openSubscriptions() { route = .subscriptions }
    func popToRoot() { route = .root }

    func pushGroup(_ id: String) { route = .nodes(id) }

    // MARK: - 节点与 pin

    func selectNode(groupID: String, nodeID: String) {
        // 测速中不允许切节点，避免列表顺序抖动
        guard proxies.testingGroup == nil else { return }
        guard let group = groups.first(where: { $0.id == groupID }),
              let node = group.nodes.first(where: { $0.id == nodeID }),
              node.isAvailable else { return }

        selectedGroupID = groupID
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            await self?.proxies.selectNode(group: groupID, node: nodeID)
        }
    }

    func togglePin(_ groupID: String) {
        proxies.togglePin(group: groupID)
    }

    // MARK: - 订阅库

    func activateSubscription(_ id: UUID) {
        guard subscriptions.contains(where: { $0.id == id }) else { return }
        activeSubscriptionID = id
    }

    func updateSubscription(_ id: UUID) {
        guard updatingSubscriptionID == nil,
              let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }

        let alwaysFails = subscriptions[index].alwaysFailsUpdate
        updatingSubscriptionID = id

        subscriptionTask?.cancel()
        subscriptionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled else { return }
            self.updatingSubscriptionID = nil

            guard let index = self.subscriptions.firstIndex(where: { $0.id == id }) else { return }
            if alwaysFails {
                self.subscriptions[index].updateFailed = true
            } else {
                self.subscriptions[index].updateFailed = false
                self.subscriptions[index].updatedText = "刚刚更新"
            }
        }
    }

    func renameSubscription(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[index].name = trimmed
    }

    func deleteSubscription(_ id: UUID) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let removed = subscriptions[index]
        let wasActive = activeSubscriptionID == id

        subscriptions.remove(at: index)
        if updatingSubscriptionID == id { updatingSubscriptionID = nil }

        if wasActive {
            activeSubscriptionID = subscriptions.first?.id
            showNotice("已删除「\(removed.name)」，将停止内核")
        }
    }

    func addSubscription(url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendSubscription(name: "新订阅 \(subscriptions.count + 1)", source: .url)
    }

    func addLocalSubscription() {
        appendSubscription(name: "本地 规则集 \(subscriptions.count + 1)", source: .local)
    }

    private func appendSubscription(name: String, source: SubscriptionSource) {
        let profile = SubscriptionProfile(
            name: name,
            source: source,
            updatedText: "刚刚更新",
            quotaText: nil,
            expiryText: nil,
            updateFailed: false
        )
        subscriptions.append(profile)
        if activeSubscriptionID == nil { activeSubscriptionID = profile.id }
    }

    private func showNotice(_ text: String) {
        subscriptionNotice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.subscriptionNotice = nil
        }
    }

    // MARK: - 节点测速（真实 `/group/{name}/delay`）

    func isSpeedTesting(_ groupID: String) -> Bool { proxies.testingGroup == groupID }

    func testAllNodes(in groupID: String) {
        guard proxies.testingGroup == nil else { return }
        guard let group = groups.first(where: { $0.id == groupID }) else { return }

        guard !group.nodes.isEmpty else {
            showSpeedNotice("没有可测速的节点")
            return
        }

        speedTask?.cancel()
        speedTask = Task { [weak self] in
            guard let self else { return }
            await self.proxies.testAll(group: groupID)
            guard !Task.isCancelled else { return }

            if let error = self.proxies.lastError {
                self.showSpeedNotice(error)
            } else {
                self.flashSpeedResult()
            }
        }
    }

    private func flashSpeedResult() {
        speedResultFlash = true
        speedFlashTask?.cancel()
        speedFlashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.speedResultFlash = false
        }
    }

    private func showSpeedNotice(_ text: String) {
        speedNotice = text
        speedNoticeTask?.cancel()
        speedNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled else { return }
            self.speedNotice = nil
        }
    }

    // MARK: - 流量（1Hz 假数据）

    /// v0.1 没接管流量，不跑假数据源：速率与曲线一律走空态。
    /// v0.2 接 `/traffic` 后，把这里换成真实采样再打开。
    private func startTrafficFeed() {
        guard systemProxyOn, feedTask == nil else { return }
        feedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.tickTraffic()
            }
        }
    }

    private func tickTraffic() {
        downRate = min(max(downRate + Double.random(in: -0.9 ... 0.9), 0.6), 12)
        upRate = min(max(upRate + Double.random(in: -0.22 ... 0.22), 0.1), 3.2)

        downSeries.removeFirst()
        downSeries.append(min(1, downRate / 12))
        upSeries.removeFirst()
        upSeries.append(min(1, upRate / 3.2))
    }

    // MARK: - 底栏

    func refreshProfile() {
        updatedText = "刚刚更新"
    }

    // MARK: - 假数据（订阅库）

    static func makeSubscriptions() -> [SubscriptionProfile] {
        [
            SubscriptionProfile(
                name: "机场 A",
                source: .url,
                updatedText: "3 小时前更新",
                quotaText: "12.3/100 GB",
                expiryText: "12/3 到期",
                updateFailed: false
            ),
            SubscriptionProfile(
                name: "备用 机场 B",
                source: .url,
                updatedText: "1 天前更新",
                quotaText: nil,
                expiryText: nil,
                updateFailed: true,
                alwaysFailsUpdate: true
            ),
            SubscriptionProfile(
                name: "本地 规则集",
                source: .local,
                updatedText: "5 天前更新",
                quotaText: nil,
                expiryText: nil,
                updateFailed: false
            )
        ]
    }

    #if DEBUG
    /// Preview 夹具：直接摆出启动失败态（不启动内核）
    func previewFailure() {
        kernel.applyPreviewFailure()
    }

    /// Preview 夹具：不启动内核，摆出两张卡（仅设计预览用）
    func applyPreviewGroups() {
        proxies.applyPreviewFixture()
    }

    /// Preview 夹具：把所有可 pin 的组都 pin 上
    func pinAllPreviewGroups() {
        proxies.previewPinAllGroups()
    }
    #endif
}

// MARK: - 布局派生值
//
// 面板高度 = 内容自然高度（§3.5）；banner 在固定头部占位，只从分组区里扣。

extension PanelPreviewModel {
    var groupSectionHeight: CGFloat {
        if groups.isEmpty { return Metrics.emptyGroupCardHeight }
        let base = Metrics.groupSectionHeight(forCards: pinnedGroups.count)
        return base - (showsErrorBanner ? Metrics.bannerBlockHeight : 0)
    }

    /// 内核启动失败：分组区变暗并禁用（§7）
    var isGroupDisabled: Bool { showsErrorBanner || status == .failed }
}
