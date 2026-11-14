// TODO(v0.3): 设置窗口仍是占位；连接列表 / 日志窗口已接真实数据
import CoreGraphics
import Foundation
import Observation

/// 面板模型：内核生命周期 / 策略组 / 订阅库 / 实时流量全部来自真实服务。
///
/// 视图只和本模型打交道；内核状态、策略组、节点、模式、订阅、流量都在本模型里转发一次，
/// 避免 View 直接依赖 `KernelService` / `ProxyService` / `TrafficService` / `ProfileStore`。
///
/// **已经是真的**：
/// - 内核生命周期（`phase` / `lastError`），来自 `KernelService`
/// - **系统代理总开关**（快照 → 写入 → 读回校验 → 失败回滚），来自 `SystemProxyService`
/// - 策略组 / 节点 / 延迟 / 选中项 / 模式，来自 `ProxyService`（`GET /proxies`、`GET /configs`）
/// - 订阅库（列表 / 激活 / 导入 / 更新 / 重命名 / 删除），来自 `ProfileStore`
///   （`profiles/index.json` + `profiles/<id>.yaml`）
/// - 实时速率与 60 点曲线，来自 `TrafficService`（`/traffic` WS，1Hz）
/// - 连接列表（条数 / 规则 / 节点 / 关闭），来自 `ConnectionService`（`/connections`，面板打开时 2s 轮询）
/// - 日志窗口（级别 / 暂停 / 清空 / 导出），来自 `LogStore`（`/logs` WS，窗口打开期间才连）
/// - TUN（安装引导 / root 内核启停 / 端点接管），来自 `TunService`（helper + XPC）
///
/// **还没接的**：设置窗口的组件卸载入口。
@MainActor
@Observable
final class PanelPreviewModel {

    // MARK: 内核 / 系统代理 / 模式 / TUN

    /// 真实内核生命周期；`phase` / `errorMessage` 都从这里转发
    @ObservationIgnored let kernel: KernelService
    /// 真实系统代理（快照落盘 + 逐服务还原）
    @ObservationIgnored private let systemProxy: SystemProxyService
    /// 真实策略组 / 节点 / 模式
    @ObservationIgnored let proxies: ProxyService
    /// 真实订阅库（`profiles/index.json`）
    @ObservationIgnored private let profiles: ProfileStore
    /// 真实流量采样（`/traffic` WS）
    @ObservationIgnored private let traffic: TrafficService
    /// 真实连接列表（`/connections` 轮询）
    @ObservationIgnored let connections: ConnectionService
    /// TUN（helper 安装 / 授权 / root 内核启停）
    @ObservationIgnored let tun: TunService
    /// 日志窗口的缓冲与 `/logs` WS（窗口打开才连，关窗即停）
    @ObservationIgnored let logStore: LogStore
    /// 应用设置（端口 / UA / 日志级别 / 关代理是否保留内核）
    @ObservationIgnored let settings: SettingsStore
    /// 规则列表（`GET /rules`，进页面拉一次 + 缓存）
    @ObservationIgnored let ruleService: RuleService
    /// 节点测速编排（Task / 提示 / 闪烁）
    @ObservationIgnored private let speed: SpeedTestController
    /// 订阅写操作编排（切换 / 更新 / 导入 / 重启内核）
    @ObservationIgnored let actions: SubscriptionActions
    /// 网络检测（URLSession 直连四个固定目标，5s 超时）
    @ObservationIgnored let networkProbes = NetworkProbeService()

    /// 系统代理磁贴的五态（§4.2）；启用 / 停用成功与否都以读回校验为准
    var connectionState: ConnectionState = .off
    /// 系统代理操作的失败文案（优先于内核错误进 banner）
    private(set) var connectionError: String?

    /// 我们是否正在接管系统代理（快照存在且未还原）
    var isSystemProxyOn: Bool { systemProxy.isEnabled }

    /// 系统代理磁贴实际展示的状态：`.on` / `.off` 以系统代理真实开关为准。
    ///
    /// TUN 与系统代理互斥，TUN 开启会在 `TunService` 里直接关掉系统代理；这条路径
    /// 不经过本模型的 `connectionState`，所以磁贴必须以 `systemProxy.isEnabled` 为准，
    /// 否则会一直显示「已启用」。过渡 / 失败态保留原值。
    var connectionTileState: ConnectionState {
        switch connectionState {
        case .turningOn, .turningOff, .failed(_):
            return connectionState
        case .on, .off:
            return systemProxy.isEnabled ? .on : .off
        }
    }

    /// 内核当前模式（`GET /configs` 为准）；内核还没拉到数据时先显示设置里持久化的值，
    /// 避免重启瞬间面板从「全局」闪回「规则」。
    var mode: ProxyMode { proxies.hasLoaded ? proxies.mode : settings.mode }

    /// 失败文案：TUN / 代理操作失败优先，其次内核启动失败
    var errorMessage: String? { tun.bannerMessage ?? connectionError ?? kernel.lastError?.userMessage }

    /// 是否展示 banner（派生，不再手动置位）
    var showsErrorBanner: Bool { errorMessage != nil }

    // MARK: 导航（首层 / 二级）

    var route: PanelRoute = .root

    // MARK: 分组与订阅

    /// 首屏 / 列表用的策略组（不含 `GLOBAL`），来自内核
    var groups: [ProxyGroupModel] { proxies.groups }
    /// 全部策略组（含 `GLOBAL`），供「全部策略组」二级页
    var allGroups: [ProxyGroupModel] { proxies.allGroups }
    /// 当前展示组 id：「全部策略组」的选中行 + 首屏唯一一张卡
    var displayedGroupID: String? { displayedGroup?.name }

    var subscriptions: [ProfileEntry] { profiles.entries }
    var activeSubscriptionID: String? { profiles.activeProfileID }

    // 订阅写操作的 UI 状态由 `SubscriptionActions` 持有，这里只转发（View 不变）
    var updatingProfileID: String? { actions.updatingProfileID }
    var isImportingProfile: Bool { actions.isImportingProfile }
    var importError: String? { actions.importError }
    var recentlyImportedProfileID: String? { actions.recentlyImportedProfileID }
    var subscriptionNotice: String? { actions.notice }
    /// 测速提示 / 完成闪烁：由 `SpeedTestController` 持有，这里只转发
    var speedNotice: String? { speed.notice }
    var speedResultFlash: Bool { speed.resultFlash }

    /// 实时速率（字节 / 秒）与 60 点曲线，均来自 `TrafficService`
    var downRate: Double { traffic.down }
    var upRate: Double { traffic.up }
    var downSeries: [Double] { traffic.downSeries }
    var upSeries: [Double] { traffic.upSeries }
    /// 有采样就画曲线；没有采样走「暂无流量」空态
    var hasTrafficCurve: Bool { traffic.hasSamples }
    /// WS 断连：曲线保留但降透明度、数值回到 `—`（§4.5 断连态）
    var isTrafficStale: Bool { !traffic.isStreaming }

    /// 面板显隐（唯一入口 `PanelWindowController`）：收起时流量不再发布给 UI，
    /// 避免隐藏窗口跟着每秒采样离屏重绘（GPU 表面会被一直占着）。
    /// 显示时顺手检查网络检测：超过 60s 没测过就自动测一轮（§3.2）。
    func setPanelVisible(_ visible: Bool) {
        traffic.setPanelVisible(visible)
        if visible { networkProbes.testIfStale() }
    }

    // MARK: 连接列表（`/connections`）

    /// 连接列表数据由 `ConnectionService` 持有；只有二级页打开期间才轮询
    var connectionEntries: [ConnectionEntry] { connections.entries }
    var connectionCount: Int { connections.count }
    var connectionsTotalUp: Int64 { connections.totalUp }
    var connectionsTotalDown: Int64 { connections.totalDown }
    var connectionsError: String? { connections.lastError }

    // MARK: 网络检测（URLSession 直连，不走 App 的 API 客户端）

    /// 四个固定目标（顺序即磁贴顺序）
    var networkProbeTargets: [NetworkProbeService.Target] { NetworkProbeService.Target.allCases }
    /// 单目标当前状态：未测 / 测速中 / 延迟 / 超时
    func networkProbeState(for target: NetworkProbeService.Target) -> NetworkProbeService.State {
        networkProbes.state(for: target)
    }
    /// 是否正在测（标题行按钮据此换 ProgressView 并禁用）
    var isTestingNetworkProbes: Bool { networkProbes.isTesting }
    /// 点任一磁贴 / 标题行刷新：四个一起重测
    func testNetworkProbes() { networkProbes.testAll() }

    // MARK: 规则列表（`GET /rules`）

    var rules: [RuleEntry] { ruleService.rules }
    var rulesCount: Int { ruleService.rules.count }
    var rulesError: String? { ruleService.lastError }
    var hasLoadedRules: Bool { ruleService.hasLoaded }

    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    /// 内核生命周期串行链：同一时刻只有一条 start / stop 在跑
    @ObservationIgnored private var kernelTask: Task<Void, Never>?
    /// 串行链代号：新指令让旧指令让位，保证「只保留最新意图」
    @ObservationIgnored private var kernelTaskID = 0
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var modeTask: Task<Void, Never>?
    @ObservationIgnored private var proxyRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?

    init(
        kernel: KernelService? = nil,
        profileStore: ProfileStore? = nil,
        systemProxy: SystemProxyService = SystemProxyService(),
        settings: SettingsStore? = nil,
        tun: TunService? = nil,
        autoStartsKernel: Bool = true
    ) {
        // 设置只允许一份实例：内核注入端口 / 模型读端口 / 设置窗口写端口必须是同一个对象
        let resolvedSettings = settings ?? kernel?.settings ?? SettingsStore()
        let resolvedKernel = kernel ?? KernelService(settings: resolvedSettings)
        let resolvedProfileStore = profileStore ?? ProfileStore(
            settings: resolvedSettings,
            latencyCache: .shared
        )

        self.settings = resolvedSettings
        self.kernel = resolvedKernel
        self.profiles = resolvedProfileStore
        self.systemProxy = systemProxy
        let resolvedTun = tun ?? TunService(
            settings: resolvedSettings,
            systemProxy: systemProxy,
            kernel: resolvedKernel
        )
        self.tun = resolvedTun
        let resolvedProxies = ProxyService(
            kernel: resolvedKernel,
            profileStore: resolvedProfileStore,
            latencyCache: .shared
        )
        self.proxies = resolvedProxies
        self.traffic = TrafficService(kernel: resolvedKernel)
        self.connections = ConnectionService(kernel: resolvedKernel)
        self.logStore = LogStore(kernel: resolvedKernel)
        self.ruleService = RuleService(kernel: resolvedKernel)
        self.speed = SpeedTestController(proxies: resolvedProxies)
        self.actions = SubscriptionActions(
            profiles: resolvedProfileStore,
            kernel: resolvedKernel,
            systemProxy: systemProxy,
            tun: resolvedTun
        )
        self.connectionState = systemProxy.isEnabled ? .on : .off
        actions.attach(host: self)

        // 内核一就绪就拉真实策略组；停止 / 失败即清空
        resolvedKernel.onPhaseChange = { [weak self] phase in
            self?.handleKernelPhase(phase)
        }

        // 退出顺序（先还原系统代理、再停内核）由 `AppTerminationGuard` 统一负责，
        // 覆盖 ⌘Q 与 SIGTERM / SIGINT / SIGHUP 三条路径。

        bootstrap(autoStartsKernel: autoStartsKernel)
    }

    // MARK: - 派生状态

    /// 内核相位（转发 `KernelService`，只读）
    var phase: KernelPhase { kernel.phase }

    /// 内核 / geodata 下载进度（ADR-0012）：`idle` / `downloading` / `verifying` / `ready` / `failed`
    var kernelProvisioning: KernelProvisioner.Phase { kernel.provisioningPhase }
    /// 状态条副文案：下载百分比 / 校验中；`nil` = 没有额外阶段要展示
    var kernelProvisioningStage: String? { kernel.provisioningPhase.statusText }
    /// 不确定进度条用；总长度未知时为 nil
    var kernelProvisioningProgress: Double? { kernel.provisioningPhase.progress }

    /// 系统代理与 TUN 都关着时，磁贴下方露一行「任选其一」提示。
    ///
    /// 两者是替代关系（互斥，开一个必关另一个），都关着恰恰是最容易误读成
    /// 「两个都要开」的时刻；任一已启用 / 过渡中 / 失败都不再显示——那时用户已经选好了路。
    var showsTransportHint: Bool {
        connectionTileState == .off && tunState == .off
    }

    /// 系统代理磁贴不可再点：内核启停中、系统代理正在写入、TUN 正在过渡，或正在升级内核
    var isConnectionBusy: Bool {
        isUpdatingKernel || kernel.isTransitioning || connectionState.isBusy || tun.isBusy
    }

    /// 正在升级内核（设置页触发）：期间禁用 TUN / 代理开关，面板显示「正在更新内核…」
    private(set) var isUpdatingKernel = false

    /// 面板状态条副文案：升级中优先于启动阶段
    var kernelUpdateStatus: String? {
        guard isUpdatingKernel else { return nil }
        guard let progress = kernelProvisioningProgress else { return "正在更新内核…" }
        return "正在更新内核… \(Int(progress * 100))%"
    }

    /// 状态条文案（§3.3）：内核 running + 代理关 = 已就绪，代理开 = 代理中。
    ///
    /// 系统代理磁贴只表示系统代理，内核由 App 生命周期管理，所以「代理关」不再是「未运行」。
    var status: DemoStatus {
        switch phase {
        case .stopped:
            return .idle
        case .starting:
            return .starting
        case .failed:
            return .failed
        case .running:
            return isSystemProxyOn ? .proxying : .ready
        }
    }

    /// 是否有实时速率可展示：**只看内核与 WS 状态，与系统代理开关无关**（§3.3）。
    /// 内核查在跑就有流量数据；代理关时通常接近 0，但仍应显示 `0.0 B/s` 而不是 `—`。
    var showsLiveTraffic: Bool { phase == .running && traffic.isStreaming }

    var downRateText: String { TrafficFormat.rate(downRate) }
    var upRateText: String { TrafficFormat.rate(upRate) }

    /// 首屏展示的策略组（单选）：用户选过的优先（`settings.displayedGroup`，跨启动保留）；
    /// 组不存在 / 从没选过 → 第一个生效组 → 配置里第一组。
    var displayedGroup: ProxyGroupModel? {
        if let name = settings.displayedGroup,
           let group = allGroups.first(where: { $0.name == name }) {
            return group
        }
        return groups.first(where: { proxies.effectiveGroupNames.contains($0.name) }) ?? groups.first
    }

    /// 首屏卡片 / 「全部策略组」行尾是否标「未生效」（规则快照可用、非 `GLOBAL`、且没被任何规则引用）
    func showsInactiveLabel(for group: ProxyGroupModel) -> Bool {
        guard proxies.hasRuleSnapshot, !group.isGlobal else { return false }
        return !proxies.effectiveGroupNames.contains(group.name)
    }

    /// 空态文案：没配置「还没有配置」/ 有配置但内核没跑「内核未运行」/ 跑了但没组「当前配置没有策略组」
    var emptyGroupTitle: String {
        guard hasConfiguredProfile else { return "还没有配置" }
        if proxies.hasLoaded { return "当前配置没有策略组" }
        return phase == .failed ? "内核未运行" : "正在启动内核"
    }

    /// 已经导入订阅就不摆「导入订阅」按钮：用户不是没导入，只是内核还没就绪
    var showsEmptyGroupImportActions: Bool { !hasConfiguredProfile }

    /// 是否已有可用配置：订阅库有 active，或本次内核用了用户配置（DEBUG 的 `CLASH_PROFILE` 也算）
    var hasConfiguredProfile: Bool { activeSubscription != nil || kernel.hasProfile }

    var activeSubscription: ProfileEntry? { profiles.activeProfile }

    /// 磁贴四行内容（名称 / 用量 / 到期）与无障碍描述；缺字段即省行（§4.2）
    var subscriptionTileContent: SubscriptionTileContent {
        guard let active = activeSubscription else { return .empty }
        return active.tileContent(badgeCount: subscriptionBadgeCount)
    }

    var subscriptionBadgeCount: Int { subscriptions.count }

    /// 订阅页三态（§4.8）：读取中 / 读取失败（带 `ProfileStore` 的失败文案）/ 已加载
    var subscriptionPanelState: SubscriptionPanelState { profiles.loadState.panelState }

    // MARK: - 内核相位

    private func handleKernelPhase(_ phase: KernelPhase) {
        switch phase {
        case .running:
            proxyRefreshTask?.cancel()
            proxyRefreshTask = Task { [weak self] in
                guard let self else { return }
                // 回退判断只在**成功刷新之后**做：刷新前先动路由，只会把用户从
                // 还在的页面打回首层（内核重启 = 订阅更新 / 开关 TUN 的必经路径）
                guard await self.proxies.refresh() else { return }
                guard !Task.isCancelled else { return }
                self.pruneRouteIfTargetMissing()
            }
            // 内核 running（含重启后新端口 / 新 secret）：重建 `/traffic` 连接
            traffic.start()
            // 内核 restart（更新订阅 / 开关 TUN 必经 stop→start）在 `.stopped` 里停了轮询；
            // 用户还停在连接页时要把轮询接回来，否则列表清空后再不刷新（只能退出页面重进）。
            if route == .connections {
                connections.startPolling()
            }
            // 同理：停在规则页时内核重启过（缓存已作废），这里补拉一次
            if route == .rules {
                Task { [weak self] in await self?.ruleService.loadIfNeeded() }
            }
        case .stopped, .failed:
            // 相位变化不再清空策略组、不再重置路由：开关代理 / TUN / 更新订阅都会
            // 让内核 stop → start，清空只会让面板在开关瞬间塌成空态再长回来。
            // 保留最后一次快照；`running` 后由 refresh 覆盖。
            proxyRefreshTask?.cancel()
            traffic.stop()
            connections.stopPolling()
            connections.clear()
            // 规则是配置派生的：内核停了 / 换了配置，缓存不再可信，下次进页面重拉
            ruleService.invalidate()
            if phase == .failed {
                // 内核异常退出：先撤系统代理，不能让用户对着死内核被代理
                restoreProxyAfterKernelFailure()
            }
        case .starting:
            break
        }
    }

    /// 路由指向的对象真的没了才回退（例如 `.nodes(id)` 的组在新一次刷新后消失）。
    ///
    /// 订阅 / 设置 / 连接列表 / 全部策略组与内核相位无关，一律不动。
    func pruneRouteIfTargetMissing() {
        guard case .nodes(let id) = route else { return }
        guard !proxies.allGroups.contains(where: { $0.id == id }) else { return }
        popToRoot()
    }

    // MARK: - App 启动 / 内核生命周期

    /// App 启动：先兜底还原上次会话遗留的系统代理，再在有激活订阅时静默启动内核。
    ///
    /// 内核由 App 生命周期管理，与系统代理解耦（架构 §4）：启动后即使不开启代理，
    /// 面板也能立刻拿到节点供挑选 / 测速。
    private func bootstrap(autoStartsKernel: Bool) {
        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            guard let self else { return }

            // 新进程里内核还没跑：盘上留着的快照一定来自旧会话（指向已死端口），必须还原
            await self.systemProxy.restoreIfNeeded()
            guard !Task.isCancelled else { return }

            self.connectionState = self.systemProxy.isEnabled ? .on : .off
            if let error = self.systemProxy.lastError {
                self.failConnection(.disable, message: error.userMessage)
            }

            guard autoStartsKernel else { return }
            // 没有订阅就不启动内核，保留空态引导导入
            self.startKernelIfNeeded()
        }
    }

    /// 自动启动内核（App 启动 / 订阅切换 / 失败后切换订阅共用）。
    ///
    /// 防抖：相位已 running、正在过渡、或启动链已排队时直接返回，重复调用只会触发一次 start。
    private func startKernelIfNeeded() {
        guard hasConfiguredProfile else { return }
        guard kernel.phase != .running, !kernel.isTransitioning else { return }
        guard kernelTask == nil else { return }
        enqueueKernelOperation { [weak self] in
            await self?.kernel.start()
        }
    }

    /// 内核生命周期串行化：同一时刻只有一条 start / stop 链，
    /// 因此不会在 `isTransitioning` 期间并发 start。
    ///
    /// 新操作排在链尾；**正在跑的旧操作会被取消**（不是只跳过排队中的那些）：
    /// 快速连切订阅时，旧操作可能正卡在 `kernel.start()` 的 8s 就绪 / 20s 流水线里，
    /// 光换 `kernelTaskID` 要等它自己跑满超时，最终会看到 `startTimeout`。
    /// 取消后 `KernelService.start()` 会安静让位，新操作才拿得到串行链。
    func enqueueKernelOperation(_ operation: @escaping @MainActor () async -> Void) {
        kernelTaskID += 1
        let operationID = kernelTaskID
        let previous = kernelTask
        previous?.cancel()
        kernelTask = Task { [weak self] in
            await previous?.value
            guard let self, self.kernelTaskID == operationID else { return }
            await operation()
            if self.kernelTaskID == operationID { self.kernelTask = nil }
        }
    }

    // MARK: - 系统代理磁贴（总开关）

    /// 未启用 → 内核没跑先启动，再接管系统代理（内核继续跑时只补代理）；已启用 → 只还原系统代理。
    /// 过渡中忽略点击。
    func toggleConnection() {
        // 内核过渡中：先说清原因（否则 isConnectionBusy 会静默吞掉这一下，用户以为点坏了）；
        // 也不能往下走——`kernel.start()` 在过渡中会直接返回，最后只会报「内核未能就绪」。
        guard !kernel.isTransitioning else {
            connectionError = "内核正在启动，请稍候"
            return
        }
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

            // 与 TUN 互斥：先关 TUN（TUN 的 root 内核与本地内核抢同一个 mixed-port），
            // 且不在这里让 TUN 顺带重启本地内核——下面按代理解锁的顺序自己起
            if self.tun.isHelperKernelRunning {
                await self.tun.disable(restartLocalKernel: false)
                guard !Task.isCancelled else { return }
                self.connectionState = .off
                guard !self.tun.isOn else {
                    self.failConnection(
                        .enable,
                        message: self.tun.failureMessage ?? "TUN 未能关闭，代理没有开启"
                    )
                    return
                }
            }

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
                try await self.systemProxy.enable(port: self.settings.mixedPort)
                guard !Task.isCancelled else { return }
                self.connectionState = .on
                self.connectionError = nil
            } catch {
                self.failConnection(.enable, error: error)
            }
        }
    }

    /// 关闭：先还原系统代理；`keepKernelOnProxyOff` 为 false 时额外停内核。
    /// 默认保留内核——关代理后节点仍可见可选（架构 §4）。
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
            self.connectionState = .off

            guard !self.settings.keepKernelOnProxyOff else { return }
            guard self.kernel.phase == .running, !self.kernel.isTransitioning else { return }
            self.enqueueKernelOperation { [weak self] in
                await self?.kernel.stop()
            }
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

    func failConnection(_ stage: ConnectionState.Stage, error: Error) {
        let message = (error as? SystemProxyError)?.userMessage ?? "代理操作失败"
        failConnection(stage, message: message)
    }

    private func failConnection(_ stage: ConnectionState.Stage, message: String) {
        connectionState = .failed(stage)
        connectionError = message
    }

    // MARK: - 设置联动（端口 / 日志级别 / 完全清理）

    /// 本次运行实际注入的端口 / 日志级别 / 局域网访问（`KernelService` 记录）
    var kernelActiveMixedPort: Int? { kernel.activeMixedPort }
    var kernelActiveLogLevel: String? { kernel.activeLogLevel }
    var kernelActiveAllowLAN: Bool? { kernel.activeAllowLAN }

    /// 设置里的值已改但内核还在用旧值：设置窗口据此提示「需要重启内核生效」
    var needsKernelRestartForSettings: Bool {
        guard phase == .running else { return false }
        return kernel.activeMixedPort != settings.mixedPort
            || kernel.activeLogLevel != settings.logLevel.cliValue
            || kernel.activeAllowLAN != settings.allowLAN
    }

    /// 重启中（stop → start 或代理由重开）：设置窗口的「立即重启」禁用
    var isApplyingSettings: Bool {
        isUpdatingKernel || kernel.isTransitioning || connectionState.isBusy
    }

    // MARK: - 内核版本（设置页）

    /// 已安装版本（本地文件，不联网）；`nil` = 未安装
    var kernelInstalledVersion: String? { kernel.provisioner.installedVersion }

    /// 进入设置页时刷新一次（只读本地 `kernel/VERSION`）
    func refreshKernelVersion() {
        kernel.provisioner.refreshInstalledVersion()
    }

    /// 「下载并安装」（未安装态）：本地没有内核 → 直接走首次下载，不做版本比较
    func installKernelIfMissing() async -> String? {
        guard !kernel.isTransitioning, !isUpdatingKernel else { return "内核正在启动/更新，请稍后" }
        isUpdatingKernel = true
        defer { isUpdatingKernel = false }
        do {
            try await kernel.ensureKernelAvailable()
            if hasConfiguredProfile {
                await kernel.start()
            }
            if kernel.phase == .failed {
                return kernel.lastError?.userMessage ?? "内核安装后启动失败，请查看日志"
            }
            return nil
        } catch {
            return (error as? KernelProvisionError)?.userMessage ?? error.localizedDescription
        }
    }

    /// 「检查更新」：**只发一次 GitHub API 请求，不下载任何资产**。
    ///
    /// 顺序（硬约束，避免「先下后判」）：
    /// 1. 先刷新本地 `installedVersion`（读 `kernel/VERSION`，内置包回退 bundle）
    /// 2. 只有用户点了检查才请求 `latestVersion()`；10 分钟内重复点走缓存
    /// 3. 比较交给 UI：`latest == installed` → 直接显示「已是最新」，不触发下载
    func checkKernelUpdate() async throws -> String {
        kernel.provisioner.refreshInstalledVersion()
        return try await kernel.provisioner.latestVersion()
    }

    /// 升级内核：停 → 换文件 → 起（进程归 `KernelService`，provisioner 只换文件）。
    ///
    /// - Returns: `nil` = 成功；否则是给用户看的一句话。
    func updateKernel(to tag: String) async -> String? {
        // 内核启动 / 停止过渡中：`kernel.stop()` 会静默返回，随后 `mihomo -t` 与新进程
        // 会与正在 spawn 的内核抢同一份 `kernel/` 与 `runtime.yaml`，必须整段拒绝。
        guard !kernel.isTransitioning, !isUpdatingKernel else { return "内核正在启动/更新，请稍后" }
        // TUN 的内核是 helper 的 root 副本（/Library/PrivilegedHelperTools/mihomo）：
        // 更新用户目录那份不会影响它，先让用户关 TUN，别制造「更新了但没生效」
        if tun.isHelperKernelRunning {
            return "TUN 接管中：内核由特权组件持有，请先关闭 TUN 再更新内核"
        }

        isUpdatingKernel = true
        defer { isUpdatingKernel = false }

        do {
            // 升级前内核在跑 → 升级后必须起来（保持用户看到的状态，不偷偷停内核）
            let wasRunning = kernel.phase == .running
            await kernel.stop()
            try await kernel.provisioner.update(to: tag)
            if wasRunning || hasConfiguredProfile {
                await kernel.start()
            }
            if kernel.phase == .failed {
                return kernel.lastError?.userMessage ?? "内核更新后启动失败，请查看日志"
            }
            return nil
        } catch {
            let message = (error as? KernelProvisionError)?.userMessage ?? error.localizedDescription
            return message
        }
    }

    /// 「立即重启」：按新设置重建 runtime 并重启内核。
    ///
    /// 端口变了而系统代理还开着的话，代理会指向死端口：先撤代理，起来后按新端口重开。
    func restartKernelForSettings() {
        // TUN 内核由 helper 持有，本 App 既不能 stop 也不能按新设置重建：
        // 先关 → 用新设置重开（失败就停在关闭态，原因由 TUN banner 给）
        if tun.isHelperKernelRunning {
            actions.reopenTunAfterConfigChange()
            return
        }
        enqueueKernelOperation { [weak self] in
            guard let self else { return }
            let wasProxied = self.isSystemProxyOn
            if wasProxied {
                do {
                    try await self.systemProxy.disable()
                    self.connectionState = .off
                } catch {
                    self.failConnection(.disable, error: error)
                    return
                }
            }

            await self.kernel.stop()
            guard self.hasConfiguredProfile else { return }
            await self.kernel.start()

            guard wasProxied, self.kernel.phase == .running else { return }
            do {
                try await self.systemProxy.enable(port: self.settings.mixedPort)
                self.connectionState = .on
                self.connectionError = nil
            } catch {
                self.failConnection(.enable, error: error)
            }
        }
    }

    /// 清理成功后的文案（UI 层展示；`performFullCleanup()` 返回 `nil` = 成功）。
    ///
    /// 数据是**移到废纸篓**而不是删除，所以必须把「可恢复」说清楚——用户当场能反悔。
    static let cleanupSuccessNotice =
        "已移到废纸篓，可从废纸篓恢复订阅与设置。"
        + "请退出并重新打开 Clash（不会自动退出），以便重建数据目录。"

    #if DEBUG
    /// 最近一次 `performFullCleanup` 实际移进废纸篓的条目（`CLASH_CLEANUP_HARNESS` 验收用）。
    /// Release 不编译：生产路径不需要知道废纸篓里的 URL。
    private(set) var cleanupTrashedURLs: [URL] = []
    #endif

    /// 「完全清理…」：还原系统代理 → 停 TUN / 内核 → 数据与缓存**移到废纸篓** → 清偏好。
    ///
    /// 清理成功后 UI 应展示 `cleanupSuccessNotice`（成功时本方法返回 `nil`）。
    ///
    /// 顺序与理由：
    /// 1. 系统代理必须先还原且**确认已关闭**（快照还在 = 代理仍指向本机端口），
    ///    否则删掉 runtime 会让用户对着死端口断网
    /// 2. TUN / 内核停不下来就中止：root 内核还在接管流量时删配置等于制造「黑盒断网」
    /// 3. 用户数据与缓存走 `trashItem`（**可恢复**）：先缓存、后数据根，任一失败立即中止，
    ///    不做「删一半」；**不碰 `/Library/Application Support/ClashHelper`**
    ///    （root 目录由 helper 自己管，卸载入口在「组件」里）
    ///
    /// - Returns: `nil` 表示成功；否则是给用户看的中文失败原因。
    func performFullCleanup() async -> String? {
        // 0. 内核正在 start/stop（含 `mihomo -t` 校验 / spawn）时，`kernel.stop()` 会静默返回，
        //    随后删 `kernel/` 与 `runtime.yaml` 等于把正在跑的内核的腿抽掉。
        guard !kernel.isTransitioning, !isUpdatingKernel else { return "内核正在启动/更新，请稍后" }

        // 1. 过渡中的任何一次系统代理写入都不能被删目录打断：
        //    此刻快照可能还没落盘（`hasSnapshot == false`），单看 hasSnapshot 会漏掉这个窗口。
        if systemProxy.isTransitioning {
            return "\(SystemProxyError.busy.userMessage)，已中止清理"
        }

        // 1. 系统代理：失败 / 仍在开启（含快照还在）都中止。
        // 用 `hasSnapshot` 而不是只看 `isEnabled`：enable 正在写入时 isEnabled 仍是 false，
        // 但快照已经落盘——此时删目录会让用户停在「代理指向死端口」。
        if systemProxy.isEnabled || systemProxy.hasSnapshot {
            do {
                try await systemProxy.disable()
                connectionState = .off
            } catch {
                let message = (error as? SystemProxyError)?.userMessage
                    ?? systemProxy.lastError?.userMessage
                    ?? "还原系统代理失败"
                return "\(message)，已中止清理"
            }
            // 不变式：没有快照才算真的还原。busy / 只抛错不落状态时这里必须拦住
            guard !systemProxy.isEnabled, !systemProxy.hasSnapshot else {
                let message = systemProxy.lastError?.userMessage ?? "系统代理仍在开启"
                return "\(message)，已中止清理"
            }
        }

        // 2. TUN：root 内核不在本进程，停不掉就不能删它要读的配置
        if tun.isHelperKernelRunning {
            await tun.disable(restartLocalKernel: false)
            if tun.isOn || tun.isHelperKernelRunning {
                return "TUN 未能关闭（\(tun.failureMessage ?? "未知原因")），已中止清理"
            }
        }

        // 3. 本地内核：`stop()` 在过渡中会静默返回，用相位复核一次（`.starting` 也还没停稳）
        await kernel.stop()
        if kernel.phase == .running || kernel.phase == .starting || kernel.isExternal {
            return "内核未能停止，已中止清理"
        }

        // 4. 移到废纸篓：整个 App 数据根（settings.json / profiles / runtime / kernel / logs / 快照）
        //    文本设置可能还有 300ms 合并写在路上：先落盘，否则删完目录它会把 settings.json 写回来；
        //    延迟缓存同理（1s 合并写），先 flush 掉在途任务，避免删完目录又被它重建
        settings.flushPendingWrite()
        LatencyCache.shared.flush()
        let fileManager = FileManager.default
        #if DEBUG
        cleanupTrashedURLs = []
        #endif
        let targets: [(String, URL)] = [
            ("缓存", AppPaths.cachesDirectory),
            ("应用数据", AppPaths.supportDirectory)
        ]
        for (name, url) in targets where fileManager.fileExists(atPath: url.path) {
            // 拿不到 resultingItemURL 也不影响成功判定；DEBUG 夹具用它做「可还原」取证
            var resulting: NSURL?
            do {
                try fileManager.trashItem(at: url, resultingItemURL: &resulting)
            } catch {
                return "移到废纸篓失败：\(name)（\(error.localizedDescription)），数据未删除"
            }
            #if DEBUG
            if let resulting { cleanupTrashedURLs.append(resulting as URL) }
            #endif
        }

        // 5. 偏好：UserDefaults 域 + plist 文件（存在才删）
        //    夹具（`CLASH_DATA_ROOT`）只改临时 plist，不碰真实偏好域
        if AppPaths.dataRootOverride == nil {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.clash.app"
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        let preferencesURL = AppPaths.preferencesPlistURL
        if fileManager.fileExists(atPath: preferencesURL.path) {
            do {
                try fileManager.removeItem(at: preferencesURL)
            } catch {
                return "删除偏好设置失败：\(error.localizedDescription)"
            }
        }

        // 内存态跟上：配置正文已删，策略组快照必须作废，否则面板还挂着上一份配置的卡片
        profiles.forgetAllAfterCleanup()
        proxies.clear()
        pruneRouteIfTargetMissing()
        connectionState = .off
        return nil
    }

    // MARK: - 代理模式

    /// 分段点击 → `PATCH /configs`；成功后写入设置（内核重启时用来重建 runtime），失败由 service 回滚
    func selectMode(_ newMode: ProxyMode) {
        guard proxies.mode != newMode else { return }
        modeTask?.cancel()
        modeTask = Task { [weak self] in
            guard let self else { return }
            await self.proxies.setMode(newMode)
            guard !Task.isCancelled, self.proxies.mode == newMode else { return }
            self.settings.mode = newMode
        }
    }

    // MARK: - TUN 磁贴（helper 安装 / 授权 / root 内核）
    //
    // 状态机与安装流程都在 `TunService` 里；这里只做转发与「与系统代理互斥」的编排。

    /// 磁贴五态（§4.2）：未启用 / 需要授权 / 等待授权 / 已启用 / 失败
    var tunState: TunState { tun.tileState }
    /// 过渡 / 授权中 / 升级内核 / 系统代理正在切换：磁贴禁用，忽略重复点击。
    ///
    /// `connectionState.isBusy` 是必须的：点完「连接」后 `systemProxy.isEnabled` 在
    /// activate 完成前仍是 false，只靠 TUN 自己的 busy 会放行 → 两个接管同开。
    var isTunBusy: Bool { isUpdatingKernel || tun.isBusy || connectionState.isBusy }
    var isTunOn: Bool { tun.isOn }

    /// 点击 TUN：安装引导 / 启动 / 关闭都由 `TunService` 的状态机决定
    func toggleTun() {
        tun.toggle()
    }

    /// 授权说明卡（非 nil 时面板弹 alert）；内容见 `TunInstallPrompt`
    var tunInstallPrompt: TunService.TunInstallBlocker? { tun.installPrompt }

    func confirmTunInstall() { tun.confirmInstallPrompt() }
    func cancelTunInstall() { tun.cancelInstallPrompt() }
    /// Esc / 点外部关闭：只收起说明卡，保持「需要授权」，不进入安装
    func dismissTunInstallPrompt() { tun.dismissInstallPrompt() }

    // MARK: - 导航

    func openAllGroups() { route = .allGroups }

    /// 订阅磁贴 → 订阅管理页。
    ///
    /// 推入前同步取一次索引快照：库还没读完（延迟加载 / 慢盘）时先读，
    /// 保证路由与数据同一帧就绪，不会先渲染空数组再补数据、闪一下白。
    func openSubscriptions() {
        if case .loading = profiles.loadState { profiles.reload() }
        route = .subscriptions
    }

    /// 订阅页失败态「重试」：重读索引（失败文案由 store 的 `lastError` 给出）
    func retrySubscriptions() { profiles.reload() }

    func openConnections() { route = .connections }

    /// 规则页：进页面由 `RulesPanelView.task` 拉一次（有缓存就不拉）
    func openRules() { route = .rules }

    func loadRulesIfNeeded() async { await ruleService.loadIfNeeded() }

    /// 规则页「重试」：重新读一次，不依赖缓存
    func refreshRules() {
        Task { [weak self] in await self?.ruleService.refresh() }
    }

    /// 设置页（`docs/02-UI-SPEC.md` §4.9）：只改路由，保证 App 层（⚙ / ⌘, / 菜单项）
    /// 与面板内推入是同一个入口；面板是否已经叫出来由 App 层负责。
    func openSettingsPage() { route = .settings }

    /// 添加订阅页（§4.10）：进入时清掉上一次的失败文案
    func openSubscriptionNewPage() {
        actions.clearImportError()
        route = .subscriptionNew
    }

    func popToRoot() {
        connections.stopPolling()
        route = .root
    }

    /// 返回上一层：添加订阅退回订阅列表，其余二级页退回首层
    func popRoute() {
        if route == .subscriptionNew {
            route = .subscriptions
        } else {
            popToRoot()
        }
    }

    func pushGroup(_ id: String) { route = .nodes(id) }

    // MARK: - 节点与展示组

    func selectNode(groupID: String, nodeID: String) {
        // 测速中不允许切节点，避免列表顺序抖动
        guard proxies.testingGroup == nil else { return }
        // 用 `allGroups`：GLOBAL 是全局模式的选节点入口，不能被 `groups`（已排除 GLOBAL）挡掉
        guard let group = allGroups.first(where: { $0.id == groupID }),
              let node = group.nodes.first(where: { $0.id == nodeID }),
              node.isAvailable else { return }

        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            await self?.proxies.selectNode(group: groupID, node: nodeID)
        }
    }

    /// 设为当前展示组（单选，替换旧的）；写 `settings.json` 的 `displayedGroup`，重启保留
    func display(groupID: String) {
        guard allGroups.contains(where: { $0.id == groupID }) else { return }
        settings.displayedGroup = groupID
    }

    // MARK: - 订阅库（真实 `profiles/index.json`）
    //
    // 写操作（切换 / 更新 / 重命名 / 删除 / 导入）与内核重启编排都在 `SubscriptionActions`；
    // 这里只保留 View 在用的同名入口，行为不变。

    // MARK: - 节点测速（真实 `/group/{name}/delay`）

    func isSpeedTesting(_ groupID: String) -> Bool { speed.isTesting(groupID) }

    func testAllNodes(in groupID: String) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        speed.testAll(in: groupID, hasNodes: !group.nodes.isEmpty)
    }

    // MARK: - 流量（真实 `/traffic` WS）
    //
    // 采样、环形缓冲与重连都在 `TrafficService` 里；这里只按内核相位起停。
    // 面板可见性在 `MenuBarExtra` 下拿不到可靠信号，因此不做「隐藏 30s 断开」：
    // 内核 running 期间保持一条常驻 WS（1Hz，可忽略的开销）。

    // MARK: - 连接列表（真实 `/connections`，2s 轮询）
    //
    // 轮询只在二级页打开期间跑（`ConnectionsPanelView` 的 onAppear / onDisappear）；
    // TODO(v1.0): 换 WS `/connections` 后删掉 `ConnectionService.startPolling` 的定时器。

    func startConnectionPolling() { connections.startPolling() }
    func stopConnectionPolling() { connections.stopPolling() }
    /// 轮询是否在跑（内核重启后必须自动接回，见 `handleKernelPhase`）
    var isConnectionPolling: Bool { connections.isPolling }

    func closeConnection(id: String) {
        Task { [weak self] in
            await self?.connections.close(id: id)
        }
    }

    func closeAllConnections() {
        Task { [weak self] in
            await self?.connections.closeAll()
        }
    }

    // MARK: - 底栏

    /// 底栏刷新按钮：有 active 订阅就真去拉一次（成功后 `updatedAt` 推进，底栏变「刚刚更新」）
    func refreshProfile() {
        guard let id = activeSubscriptionID else { return }
        updateSubscription(id)
    }
}
