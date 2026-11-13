// TODO(v0.2): 节点 / 订阅 / 流量仍是本地假数据；内核生命周期与 /version 已接真
import CoreGraphics
import Foundation
import Observation

/// v0.1 面板模型：**内核是真的**（`KernelService`），其余仍是本地假数据。
///
/// 视图只和本模型打交道；内核状态在本模型里做一次转发，
/// 避免 View 直接依赖 `KernelService`。
@MainActor
@Observable
final class PanelPreviewModel {

    // MARK: 内核 / 系统代理 / 模式 / TUN

    /// 真实内核生命周期；`phase` / `errorMessage` 都从这里转发
    @ObservationIgnored private let kernel: KernelService

    var systemProxyOn = true
    var mode: ProxyMode = .rule
    private(set) var tun: TunState = .on

    /// 内核启动失败时的用户文案；真实来源是 `KernelError.userMessage`
    var errorMessage: String? { kernel.lastError?.userMessage }

    /// 是否展示 banner（派生，不再手动置位）
    var showsErrorBanner: Bool { errorMessage != nil }

    // MARK: 导航（首层 / 二级）

    var route: PanelRoute = .root

    // MARK: 分组与订阅（假数据）

    var groups: [DemoGroup]
    var activeGroupID: UUID?
    var subscriptions: [SubscriptionProfile]
    var activeSubscriptionID: UUID?
    private(set) var updatingSubscriptionID: UUID?
    private(set) var subscriptionNotice: String?
    private(set) var testingGroupID: UUID?
    private(set) var speedNotice: String?
    /// 测速完成后的「刚刚更新」短暂提示
    private(set) var speedResultFlash = false

    var connectionCount = 12
    var updatedText = "2 分钟前更新"

    private(set) var downRate = DemoTraffic.initialDownRate
    private(set) var upRate = DemoTraffic.initialUpRate
    private(set) var downSeries = DemoTraffic.downSeries
    private(set) var upSeries = DemoTraffic.upSeries

    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var tunTask: Task<Void, Never>?
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var speedTask: Task<Void, Never>?
    @ObservationIgnored private var speedNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var speedFlashTask: Task<Void, Never>?

    init(kernel: KernelService = KernelService()) {
        self.kernel = kernel
        let initialGroups = Self.makeGroups()
        groups = initialGroups
        activeGroupID = initialGroups.first?.id
        let profiles = Self.makeSubscriptions()
        subscriptions = profiles
        activeSubscriptionID = profiles.first?.id
        startTrafficFeed()
    }

    // MARK: - 派生状态

    /// 内核相位（转发 `KernelService`，只读）
    var phase: KernelPhase { kernel.phase }

    /// 启动 / 停止过程中：连接磁贴不可再点
    var isKernelBusy: Bool { kernel.isTransitioning }

    var status: DemoStatus {
        switch phase {
        case .stopped:
            return .idle
        case .starting:
            return .starting
        case .failed:
            return .failed
        case .running:
            guard systemProxyOn else { return .ready }
            return mode == .direct ? .direct : .proxying
        }
    }

    var downRateText: String { DemoTraffic.format(rate: downRate) }
    var upRateText: String { DemoTraffic.format(rate: upRate) }

    var pinnedGroups: [DemoGroup] { groups.filter(\.isPinned) }
    var pinnedGroupIDs: Set<UUID> { Set(pinnedGroups.map(\.id)) }

    var activeSubscription: SubscriptionProfile? {
        guard let id = activeSubscriptionID else { return nil }
        return subscriptions.first { $0.id == id }
    }

    var subscriptionTileSubtitle: String? {
        guard let active = activeSubscription else { return nil }
        return active.updateFailed ? "\(active.name) · 更新失败" : active.name
    }

    var subscriptionBadgeCount: Int { subscriptions.count }

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
            if self.kernel.phase == .running {
                self.systemProxyOn = true
            }
        }
    }

    private func stopKernel() {
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            await self?.kernel.stop()
        }
    }

    // MARK: - 代理模式

    func selectMode(_ newMode: ProxyMode) {
        mode = newMode
    }

    // MARK: - TUN 磁贴

    func toggleTun() {
        switch tun {
        case .off:
            tun = .requiresAuth
            scheduleTunGrant()
        case .requiresAuth:
            tun = .waitingAuth
            scheduleTunGrant()
        case .waitingAuth:
            break
        case .on:
            tunTask?.cancel()
            tun = .off
        case .authFailed:
            tun = .requiresAuth
            scheduleTunGrant()
        }
    }

    private func scheduleTunGrant() {
        tunTask?.cancel()
        tunTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled else { return }
            self.tun = .on
        }
    }

    // MARK: - 导航

    func openAllGroups() { route = .allGroups }
    func openSubscriptions() { route = .subscriptions }
    func popToRoot() { route = .root }

    func pushGroup(_ id: UUID) { route = .nodes(id) }

    // MARK: - 节点与 pin

    func selectNode(groupID: UUID, nodeID: UUID) {
        // 测速中不允许切节点，避免列表顺序抖动
        guard testingGroupID == nil else { return }
        guard let index = groups.firstIndex(where: { $0.id == groupID }),
              let node = groups[index].nodes.first(where: { $0.id == nodeID }),
              node.latency != nil else { return }
        groups[index].selectedNodeID = nodeID
        activeGroupID = groupID
    }

    func togglePin(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }),
              !groups[index].isMainGroup else { return }
        groups[index].isPinned.toggle()
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

    // MARK: - 节点测速（本地模拟）

    func isSpeedTesting(_ groupID: UUID) -> Bool { testingGroupID == groupID }

    func testAllNodes(in groupID: UUID) {
        guard testingGroupID == nil else { return }
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }

        // 没有可测速节点（空组 / 全超时）也给一句一次性提示
        guard groups[index].nodes.contains(where: { $0.latency != nil }) else {
            showSpeedNotice("没有可测速的节点")
            return
        }

        testingGroupID = groupID
        speedTask?.cancel()
        speedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled else { return }
            self.finishSpeedTest(groupID: groupID)
        }
    }

    private func finishSpeedTest(groupID: UUID) {
        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            for nodeIndex in groups[index].nodes.indices {
                // 超时节点保持超时
                guard let latency = groups[index].nodes[nodeIndex].latency else { continue }
                groups[index].nodes[nodeIndex].latency = max(1, latency + Int.random(in: -40...40))
            }
        }
        testingGroupID = nil
        flashSpeedResult()
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

    private func startTrafficFeed() {
        guard feedTask == nil else { return }
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

    // MARK: - 假数据

    static func makeGroups() -> [DemoGroup] {
        [
            DemoGroup(
                name: "节点选择",
                nodes: [
                    DemoNode(name: "香港 01", latency: 32),
                    DemoNode(name: "日本 02", latency: 88),
                    DemoNode(name: "美国 03", latency: nil),
                    DemoNode(name: "新加坡 04", latency: 64),
                    DemoNode(name: "台湾 05", latency: 41),
                    DemoNode(name: "韩国 06", latency: 95),
                    DemoNode(name: "德国 07", latency: 210),
                    DemoNode(name: "英国 08", latency: 245),
                    DemoNode(name: "澳洲 09", latency: 312)
                ],
                isMainGroup: true
            ),
            DemoGroup(
                name: "自动选择",
                nodes: [
                    DemoNode(name: "日本 02", latency: 88),
                    DemoNode(name: "香港 01", latency: 32),
                    DemoNode(name: "新加坡 04", latency: 64),
                    DemoNode(name: "台湾 05", latency: 41),
                    DemoNode(name: "美国 03", latency: nil),
                    DemoNode(name: "韩国 06", latency: 95)
                ]
            )
        ]
    }

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
