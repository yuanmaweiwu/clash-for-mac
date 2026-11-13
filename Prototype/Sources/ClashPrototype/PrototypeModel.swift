import CoreGraphics
import Foundation
import Observation

/// 原型的唯一状态源：全是本地演示状态与假数据，没有任何网络 / 进程调用。
/// 状态栏浮层与演示窗口共享同一个实例。
@MainActor
@Observable
final class PrototypeModel {

    // MARK: 演示环境（评审栏）

    var appearance: DemoAppearance = .system
    var wallpaper: WallpaperTone = .light
    var showsErrorBanner = false
    var showsEmptyState = false
    /// 打开后，启动连接会在 1.5s 后回滚进失败态
    var simulateFailure = false
    private(set) var trafficPaused = false

    // MARK: 原型调试（离屏快照强制 hover，不影响真实交互）

    var debugHoverRowIndex: Int?
    var debugHoverCardIndex = 0
    var debugHoverHeader = false

    // MARK: 内核 / 系统代理 / 模式 / TUN

    var phase: KernelPhase = .running
    var systemProxyOn = true
    var mode: ProxyMode = .rule
    private(set) var tun: TunState = .on

    // MARK: 导航（首层 / 二级）

    var route: PanelRoute = .root

    // MARK: 分组与订阅（假数据）

    var groups: [DemoGroup]
    var subscriptions: [SubscriptionProfile]
    var activeSubscriptionID: UUID?
    private(set) var updatingSubscriptionID: UUID?
    private(set) var subscriptionNotice: String?

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

    init() {
        groups = Self.makeGroups()
        let profiles = Self.makeSubscriptions()
        subscriptions = profiles
        activeSubscriptionID = profiles.first?.id
        startTrafficFeed()
    }

    // MARK: - 派生状态

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

    var pushedGroup: DemoGroup? {
        guard case .nodes(let id) = route else { return nil }
        return groups.first { $0.id == id }
    }

    var activeSubscription: SubscriptionProfile? {
        guard let id = activeSubscriptionID else { return nil }
        return subscriptions.first { $0.id == id }
    }

    var subscriptionTileSubtitle: String? {
        guard !showsEmptyState, let active = activeSubscription else { return nil }
        return active.updateFailed ? "\(active.name) · 更新失败" : active.name
    }

    var subscriptionBadgeCount: Int {
        showsEmptyState ? 0 : subscriptions.count
    }

    // MARK: - 连接磁贴

    func toggleConnection() {
        switch phase {
        case .starting:
            return
        case .stopped, .failed:
            startProxy()
        case .running:
            systemProxyOn.toggle()
        }
    }

    private func startProxy() {
        transitionTask?.cancel()
        let fails = simulateFailure
        phase = .starting

        transitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(fails ? 1.5 : 0.8))
            guard let self, !Task.isCancelled else { return }
            if fails {
                self.systemProxyOn = false
                self.phase = .failed
            } else {
                self.systemProxyOn = true
                self.phase = .running
            }
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
        guard let index = groups.firstIndex(where: { $0.id == groupID }),
              let node = groups[index].nodes.first(where: { $0.id == nodeID }),
              node.latency != nil else { return }
        groups[index].selectedNodeID = nodeID
    }

    func togglePin(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }),
              !groups[index].isMainGroup else { return }
        groups[index].isPinned.toggle()
    }

    func resetPins() {
        for index in groups.indices {
            groups[index].isPinned = groups[index].isMainGroup
        }
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

    // MARK: - 流量（1Hz 假数据）

    func setTrafficPaused(_ paused: Bool) {
        guard paused != trafficPaused else { return }
        trafficPaused = paused
        if paused {
            feedTask?.cancel()
            feedTask = nil
        } else {
            startTrafficFeed()
        }
    }

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
        guard !trafficPaused else { return }

        downRate = min(max(downRate + Double.random(in: -0.9 ... 0.9), 0.6), 12)
        upRate = min(max(upRate + Double.random(in: -0.22 ... 0.22), 0.1), 3.2)

        downSeries.removeFirst()
        downSeries.append(min(1, downRate / 12))
        upSeries.removeFirst()
        upSeries.append(min(1, upRate / 3.2))
    }

    // MARK: - 底栏 / 重置 / 快照

    func refreshProfile() {
        updatedText = "刚刚更新"
    }

    func reset() {
        transitionTask?.cancel()
        tunTask?.cancel()
        subscriptionTask?.cancel()
        noticeTask?.cancel()

        phase = .running
        systemProxyOn = true
        mode = .rule
        tun = .on
        showsErrorBanner = false
        showsEmptyState = false
        simulateFailure = false
        route = .root

        groups = Self.makeGroups()
        let profiles = Self.makeSubscriptions()
        subscriptions = profiles
        activeSubscriptionID = profiles.first?.id
        updatingSubscriptionID = nil
        subscriptionNotice = nil

        downRate = DemoTraffic.initialDownRate
        upRate = DemoTraffic.initialUpRate
        downSeries = DemoTraffic.downSeries
        upSeries = DemoTraffic.upSeries
        updatedText = "2 分钟前更新"

        if trafficPaused { setTrafficPaused(false) }
    }

    /// 直接进失败态（快照 / 演示用）
    func enterFailedState() {
        transitionTask?.cancel()
        systemProxyOn = false
        phase = .failed
        showsErrorBanner = true
    }

    /// 快照用：把第二张卡 pin 出来
    func pinAllGroups() {
        for index in groups.indices where !groups[index].isMainGroup {
            groups[index].isPinned = true
        }
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
                quotaText: "已用 12.3/100 GB",
                expiryText: "12月3日到期",
                updateFailed: false
            ),
            SubscriptionProfile(
                name: "备用 机场 B",
                source: .url,
                updatedText: "1 天前更新",
                quotaText: nil,
                expiryText: nil,
                updateFailed: false,
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
}

// MARK: - 布局派生值
//
// 面板高度 = 内容自然高度（§3.5）：双卡 626pt、单卡 488pt；
// banner 在固定头部占位，只从分组区里扣；空态换成 120pt 占位卡后整体变矮。

extension PrototypeModel {
    var groupSectionHeight: CGFloat {
        if showsEmptyState { return Metrics.emptyGroupCardHeight }
        let base = Metrics.groupSectionHeight(forCards: pinnedGroups.count)
        return base - (showsErrorBanner ? Metrics.bannerBlockHeight : 0)
    }

    var panelHeight: CGFloat {
        if showsEmptyState {
            let bannerBlock = showsErrorBanner ? Metrics.bannerBlockHeight : 0
            return Metrics.panelHeight - Metrics.groupSectionFullHeight
                + Metrics.emptyGroupCardHeight + bannerBlock
        }
        return Metrics.panelHeight - Metrics.groupSectionFullHeight + groupSectionHeight
    }

    /// 二级面板与满态同高
    var displayedPanelHeight: CGFloat {
        route == .root ? panelHeight : Metrics.panelHeight
    }

    /// 内核启动失败：分组区变暗并禁用（§7）
    var isGroupDisabled: Bool { showsErrorBanner || status == .failed }
}
