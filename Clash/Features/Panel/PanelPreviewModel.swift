// TODO(v0.3): 流量仍是空态；内核、策略组、模式与订阅库都已接真
import CoreGraphics
import Foundation
import Observation

/// 面板模型：内核生命周期 / 策略组 / 订阅库全部来自真实服务。
///
/// 视图只和本模型打交道；内核状态、策略组、节点、模式、订阅都在本模型里转发一次，
/// 避免 View 直接依赖 `KernelService` / `ProxyService` / `ProfileStore`。
///
/// **已经是真的**：
/// - 内核生命周期（`phase` / `lastError`），来自 `KernelService`
/// - **系统代理总开关**（快照 → 写入 → 读回校验 → 失败回滚），来自 `SystemProxyService`
/// - 策略组 / 节点 / 延迟 / 选中项 / 模式，来自 `ProxyService`（`GET /proxies`、`GET /configs`）
/// - 订阅库（列表 / 激活 / 导入 / 更新 / 重命名 / 删除），来自 `ProfileStore`
///   （`profiles/index.json` + `profiles/<id>.yaml`）
///
/// **还没接的**：流量采样（`/traffic` WS）与 TUN（helper），
/// 因此速率位一律 `—`、TUN 磁贴仍是「需要管理员组件」。
@MainActor
@Observable
final class PanelPreviewModel {

    // MARK: 内核 / 系统代理 / 模式 / TUN

    /// 真实内核生命周期；`phase` / `errorMessage` 都从这里转发
    @ObservationIgnored private let kernel: KernelService
    /// 真实系统代理（快照落盘 + 逐服务还原）
    @ObservationIgnored private let systemProxy: SystemProxyService
    /// 真实策略组 / 节点 / 模式
    @ObservationIgnored private let proxies: ProxyService
    /// 真实订阅库（`profiles/index.json`）
    @ObservationIgnored private let profiles: ProfileStore

    /// 连接磁贴的五态（§4.2）；开 / 关成功与否都以读回校验为准
    private(set) var connectionState: ConnectionState = .off
    /// 系统代理操作的失败文案（优先于内核错误进 banner）
    private(set) var connectionError: String?

    /// 我们是否正在接管系统代理（快照存在且未还原）
    var isSystemProxyOn: Bool { systemProxy.isEnabled }

    /// 内核当前模式（`GET /configs` 为准）
    var mode: ProxyMode { proxies.mode }

    /// 失败文案：代理操作失败优先，其次内核启动失败
    var errorMessage: String? { connectionError ?? kernel.lastError?.userMessage }

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

    var subscriptions: [ProfileEntry] { profiles.entries }
    var activeSubscriptionID: String? { profiles.activeProfileID }
    /// 正在更新 / 导入的那一条（行里显示「更新中」）
    private(set) var updatingProfileID: String?
    private(set) var isImportingProfile = false
    private(set) var subscriptionNotice: String?
    private(set) var speedNotice: String?
    /// 测速完成后的「刚刚更新」短暂提示
    private(set) var speedResultFlash = false

    /// 底栏更新时间：无订阅 →「未导入配置」；有订阅但从未成功更新 →「尚未更新」；否则相对时间
    var footerUpdatedText: String {
        guard let profile = activeSubscription else { return "未导入配置" }
        return profile.updatedAgoText
    }
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
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var launchRestoreTask: Task<Void, Never>?

    init(
        kernel: KernelService = KernelService(),
        profileStore: ProfileStore = ProfileStore(),
        systemProxy: SystemProxyService = SystemProxyService()
    ) {
        self.kernel = kernel
        self.profiles = profileStore
        self.systemProxy = systemProxy
        self.proxies = ProxyService(kernel: kernel)
        self.connectionState = systemProxy.isEnabled ? .on : .off

        // 内核一就绪就拉真实策略组；停止 / 失败即清空
        kernel.onPhaseChange = { [weak self] phase in
            self?.handleKernelPhase(phase)
        }

        // 退出顺序：先还原系统代理（同步），再停内核
        kernel.onWillTerminate = { [weak systemProxy] in
            systemProxy?.disableSynchronouslyForTermination()
        }

        startTrafficFeed()
        restoreProxyAtLaunch()
    }

    // MARK: - 派生状态

    /// 内核相位（转发 `KernelService`，只读）
    var phase: KernelPhase { kernel.phase }

    /// 内核版本（`/version` 的 `version` 字段）；未运行时为 nil
    var kernelVersion: String? { kernel.kernelVersion }

    /// 连接磁贴不可再点：内核启停中，或系统代理正在写入
    var isConnectionBusy: Bool { kernel.isTransitioning || connectionState.isBusy }

    /// 状态条文案（§3.3）：代理中 = 内核 running 且系统代理读回校验通过。
    ///
    /// 直连模式下即使接管了系统代理也显示「直连」（§3.3 第 5 行）。
    var status: DemoStatus {
        switch phase {
        case .stopped:
            return .idle
        case .starting:
            return .starting
        case .failed:
            return .failed
        case .running:
            guard isSystemProxyOn else { return mode == .direct ? .direct : .ready }
            return mode == .direct ? .direct : .proxying
        }
    }

    /// 是否真的有流量可以展示：`/traffic` WS 还没接，速率位一律 `—`（§3.3 / §4.5）。
    var showsLiveTraffic: Bool { false }

    var downRateText: String { DemoTraffic.format(rate: downRate) }
    var upRateText: String { DemoTraffic.format(rate: upRate) }

    var pinnedGroups: [ProxyGroupModel] { proxies.pinnedGroups }
    var pinnedGroupIDs: Set<String> { Set(pinnedGroups.map(\.id)) }

    /// 空态文案：没配置「还没有配置」/ 有配置但内核没跑「启用代理后显示节点」/ 跑了但没组「当前配置没有策略组」
    var emptyGroupTitle: String {
        guard hasConfiguredProfile else { return "还没有配置" }
        return proxies.hasLoaded ? "当前配置没有策略组" : "启用代理后显示节点"
    }

    /// 已经导入订阅就不摆「导入订阅 / 选择 YAML」：用户不是没导入，只是还没启用代理
    var showsEmptyGroupImportActions: Bool { !hasConfiguredProfile }

    /// 是否已有可用配置：订阅库有 active，或本次内核用了用户配置（DEBUG 的 `CLASH_PROFILE` 也算）
    private var hasConfiguredProfile: Bool { activeSubscription != nil || kernel.hasProfile }

    var activeSubscription: ProfileEntry? { profiles.activeProfile }

    var subscriptionTileSubtitle: String? {
        guard let active = activeSubscription else { return nil }
        var text = active.name
        if active.isUpdateFailed { text += " · 更新失败" }
        if active.isExpired { text += " · 已过期" }
        return text
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
            if phase == .failed {
                // 内核异常退出：先撤系统代理，不能让用户对着死内核被代理
                restoreProxyAfterKernelFailure()
            }
        case .starting:
            break
        }
    }

    // MARK: - 启动兜底

    /// 上次退出没还原干净（崩溃 / 强杀）→ 启动时立即还原。
    /// 此刻内核一定是新起的、没在跑，所以快照存在就直接 `disable()`（`system-proxy` §6）。
    private func restoreProxyAtLaunch() {
        launchRestoreTask?.cancel()
        launchRestoreTask = Task { [weak self] in
            guard let self else { return }
            await self.systemProxy.restoreIfNeeded(kernelRunning: self.kernel.phase == .running)
            guard !Task.isCancelled else { return }
            self.connectionState = self.systemProxy.isEnabled ? .on : .off
            if let error = self.systemProxy.lastError {
                self.failConnection(.disable, message: error.userMessage)
            }
        }
    }

    // MARK: - 连接磁贴（系统代理总开关）

    /// 关闭 → 起内核 + 接管系统代理；开启 → 还原系统代理 + 停内核；过渡中忽略点击。
    func toggleConnection() {
        guard !isConnectionBusy else { return }
        if isSystemProxyOn {
            turnOffProxy()
        } else {
            turnOnProxy()
        }
    }

    /// 开启：内核未运行就先 `start()` 并等 `running`，再 `enable(port:)`。
    /// `SystemProxyService.enable` 负责「快照 → 写入 → 读回校验 → 失败回滚」，这里不重复兜底。
    private func turnOnProxy() {
        connectionTask?.cancel()
        connectionState = .turningOn
        connectionError = nil

        connectionTask = Task { [weak self] in
            guard let self else { return }

            if self.kernel.phase != .running {
                await self.kernel.start()
                guard !Task.isCancelled else { return }
                guard self.kernel.phase == .running else {
                    self.failConnection(
                        .enable,
                        message: self.kernel.lastError?.userMessage ?? "内核未能就绪，代理没有开启"
                    )
                    return
                }
            }

            do {
                try await self.systemProxy.enable(port: RuntimeConfigBuilder.defaultMixedPort)
                guard !Task.isCancelled else { return }
                self.connectionState = .on
                self.connectionError = nil
            } catch {
                self.failConnection(.enable, error: error)
            }
        }
    }

    /// 关闭：先还原系统代理，再停内核（顺序不能反，否则内核先死会留下指向死端口的代理）。
    private func turnOffProxy() {
        connectionTask?.cancel()
        connectionState = .turningOff
        connectionError = nil

        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.systemProxy.disable()
            } catch {
                self.failConnection(.disable, error: error)
                return
            }
            guard !Task.isCancelled else { return }
            // TODO(v0.2+): 设置项「关闭代理时保留内核」打开后跳过下面这行
            await self.kernel.stop()
            self.connectionState = .off
        }
    }

    /// 内核异常退出：先还原系统代理，别让用户对着一个死内核被代理（`system-proxy` §6）
    private func restoreProxyAfterKernelFailure() {
        guard systemProxy.isEnabled else { return }
        connectionTask?.cancel()
        connectionState = .turningOff
        connectionError = nil

        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.systemProxy.disable()
                self.connectionState = .off
            } catch {
                self.failConnection(.disable, error: error)
            }
        }
    }

    private func failConnection(_ stage: ConnectionState.Stage, error: Error) {
        let message = (error as? SystemProxyError)?.userMessage ?? "代理操作失败"
        failConnection(stage, message: message)
    }

    private func failConnection(_ stage: ConnectionState.Stage, message: String) {
        connectionState = .failed(stage)
        connectionError = message
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

    // MARK: - 订阅库（真实 `profiles/index.json`）

    /// 一次只跑一个订阅写操作：索引是共享状态，避免更新中被删 / 被切换
    private var isProfileBusy: Bool { updatingProfileID != nil || isImportingProfile }

    func activateSubscription(_ id: String) {
        guard !isProfileBusy else { return }
        do {
            guard try profiles.activate(id: id) == .switched else { return }
            // 切换 = 换 active + 重建 runtime + 重载；v0.3 用 stop → start 等效
            restartKernelForProfileChange()
        } catch {
            showNotice(profileErrorMessage(error, fallback: "切换失败"))
        }
    }

    func updateSubscription(_ id: String) {
        guard !isProfileBusy, profiles.entry(id: id) != nil else { return }
        updatingProfileID = id

        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.updatingProfileID = nil }

            do {
                try await self.profiles.update(id: id)
                // 更新的正是当前配置：内核在跑就重启以加载新内容
                if id == self.profiles.activeProfileID {
                    self.restartKernelForProfileChange()
                }
            } catch {
                self.showNotice("\(self.profileErrorMessage(error, fallback: "更新失败")), 继续使用旧配置")
            }
        }
    }

    func renameSubscription(_ id: String, to newName: String) {
        guard !isProfileBusy else { return }
        do {
            try profiles.rename(id: id, to: newName)
        } catch {
            showNotice(profileErrorMessage(error, fallback: "重命名失败"))
        }
    }

    func deleteSubscription(_ id: String) {
        guard !isProfileBusy, let removed = profiles.entry(id: id) else { return }
        do {
            switch try profiles.delete(id: id) {
            case .cleared:
                showNotice("已删除「\(removed.name)」，将停止内核")
                stopKernelForProfileChange()
            case .switched:
                let next = activeSubscription?.name ?? "另一条"
                showNotice("已删除「\(removed.name)」，已切换到「\(next)」")
                restartKernelForProfileChange()
            case .none:
                break
            }
        } catch {
            showNotice(profileErrorMessage(error, fallback: "删除失败"))
        }
    }

    func importSubscription(urlString: String) {
        guard !isProfileBusy else { return }
        isImportingProfile = true

        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isImportingProfile = false }

            do {
                let entry = try await self.profiles.importURL(urlString)
                // 首次导入会自动激活：内核若在跑（用的是内置空配置）就重启一次
                if entry.id == self.profiles.activeProfileID {
                    self.restartKernelForProfileChange()
                }
            } catch {
                self.showNotice(profileErrorMessage(error, fallback: "导入失败"))
            }
        }
    }

    /// UI 层（`NSOpenPanel`）选完文件后把 URL 交给 store
    func importLocalSubscription(fileURL: URL) {
        guard !isProfileBusy else { return }
        isImportingProfile = true

        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isImportingProfile = false }

            do {
                let entry = try await self.profiles.importFile(at: fileURL)
                if entry.id == self.profiles.activeProfileID {
                    self.restartKernelForProfileChange()
                }
            } catch {
                self.showNotice(profileErrorMessage(error, fallback: "导入失败"))
            }
        }
    }

    private func profileErrorMessage(_ error: Error, fallback: String) -> String {
        (error as? ProfileStoreError)?.userMessage ?? fallback
    }

    /// active 变了：内核在跑就 stop → start，让 `KernelService` 按新 active 重建 runtime
    private func restartKernelForProfileChange() {
        guard kernel.phase == .running else { return }
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            guard let self else { return }
            await self.kernel.stop()
            guard !Task.isCancelled else { return }
            await self.kernel.start()
        }
    }

    /// 库空了：停内核，避免继续跑已删除的配置
    private func stopKernelForProfileChange() {
        guard kernel.phase == .running else { return }
        transitionTask?.cancel()
        // 代理开着就必须一起撤掉，否则会指向一个已经停掉的内核
        if isSystemProxyOn {
            turnOffProxy()
            return
        }
        transitionTask = Task { [weak self] in
            await self?.kernel.stop()
        }
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
    /// v0.2 系统代理已接管，但 `/traffic` WS 还没接 → `showsLiveTraffic` 仍为 false，
    /// 速率位用 `—` 表示「代理中但还没有采样」。接流量后再打开这里。
    private func startTrafficFeed() {
        guard showsLiveTraffic, feedTask == nil else { return }
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

    /// 底栏刷新按钮：有 active 订阅就真去拉一次（成功后 `updatedAt` 推进，底栏变「刚刚更新」）
    func refreshProfile() {
        guard let id = activeSubscriptionID else { return }
        updateSubscription(id)
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
