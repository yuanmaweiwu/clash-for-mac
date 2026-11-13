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
    @ObservationIgnored private let kernel: KernelService
    /// 真实系统代理（快照落盘 + 逐服务还原）
    @ObservationIgnored private let systemProxy: SystemProxyService
    /// 真实策略组 / 节点 / 模式
    @ObservationIgnored private let proxies: ProxyService
    /// 真实订阅库（`profiles/index.json`）
    @ObservationIgnored private let profiles: ProfileStore
    /// 真实流量采样（`/traffic` WS）
    @ObservationIgnored private let traffic: TrafficService
    /// 真实连接列表（`/connections` 轮询）
    @ObservationIgnored private let connections: ConnectionService
    /// TUN（helper 安装 / 授权 / root 内核启停）
    @ObservationIgnored let tun: TunService
    /// 日志窗口的缓冲与 `/logs` WS（窗口打开才连，关窗即停）
    @ObservationIgnored let logStore: LogStore
    /// 应用设置（端口 / UA / 日志级别 / 关代理是否保留内核）
    @ObservationIgnored let settings: SettingsStore

    /// 连接磁贴的五态（§4.2）；开 / 关成功与否都以读回校验为准
    private(set) var connectionState: ConnectionState = .off
    /// 系统代理操作的失败文案（优先于内核错误进 banner）
    private(set) var connectionError: String?

    /// 我们是否正在接管系统代理（快照存在且未还原）
    var isSystemProxyOn: Bool { systemProxy.isEnabled }

    /// 连接磁贴实际展示的状态：`.on` / `.off` 以系统代理真实开关为准。
    ///
    /// TUN 与系统代理互斥，TUN 开启会在 `TunService` 里直接关掉系统代理；这条路径
    /// 不经过本模型的 `connectionState`，所以磁贴必须以 `systemProxy.isEnabled` 为准，
    /// 否则会一直显示「已开启」。过渡 / 失败态保留原值。
    var connectionTileState: ConnectionState {
        switch connectionState {
        case .turningOn, .turningOff, .failed(_):
            return connectionState
        case .on, .off:
            return systemProxy.isEnabled ? .on : .off
        }
    }

    /// 内核当前模式（`GET /configs` 为准）
    var mode: ProxyMode { proxies.mode }

    /// 失败文案：TUN / 代理操作失败优先，其次内核启动失败
    var errorMessage: String? { tun.bannerMessage ?? connectionError ?? kernel.lastError?.userMessage }

    /// 是否展示 banner（派生，不再手动置位）
    var showsErrorBanner: Bool { errorMessage != nil }

    // MARK: 导航（首层 / 二级）

    var route: PanelRoute = .root

    // MARK: 分组与订阅

    /// 策略组快照是否已过期：内核停止 / 失败时**保留最后一次快照**（面板不塌、不闪），
    /// 只置这个标记；重新 `running` 并刷新成功后才清掉。
    private(set) var isGroupDataStale = false

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
    /// 「添加订阅」页的失败文案：留在页内（输入框下的红字），不弹窗、不进 banner
    private(set) var importError: String?
    /// 刚导入成功的那一条：回到订阅列表时短暂高亮，让用户看见结果
    private(set) var recentlyImportedProfileID: String?
    private(set) var subscriptionNotice: String?
    private(set) var speedNotice: String?
    /// 测速完成后的「刚刚更新」短暂提示
    private(set) var speedResultFlash = false

    /// 实时速率（字节 / 秒）与 60 点曲线，均来自 `TrafficService`
    var downRate: Double { traffic.down }
    var upRate: Double { traffic.up }
    var downSeries: [Double] { traffic.downSeries }
    var upSeries: [Double] { traffic.upSeries }
    /// 有采样就画曲线；没有采样走「暂无流量」空态
    var hasTrafficCurve: Bool { traffic.hasSamples }
    /// WS 断连：曲线保留但降透明度、数值回到 `—`（§4.5 断连态）
    var isTrafficStale: Bool { !traffic.isStreaming }

    // MARK: 连接列表（`/connections`）

    /// 连接列表数据由 `ConnectionService` 持有；只有二级页打开期间才轮询
    var connectionEntries: [ConnectionEntry] { connections.entries }
    var connectionCount: Int { connections.count }
    var connectionsTotalUp: Int64 { connections.totalUp }
    var connectionsTotalDown: Int64 { connections.totalDown }
    var connectionsError: String? { connections.lastError }

    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    /// 内核生命周期串行链：同一时刻只有一条 start / stop 在跑
    @ObservationIgnored private var kernelTask: Task<Void, Never>?
    /// 串行链代号：新指令让旧指令让位，保证「只保留最新意图」
    @ObservationIgnored private var kernelTaskID = 0
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var importHighlightTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var speedTask: Task<Void, Never>?
    @ObservationIgnored private var speedNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var speedFlashTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var modeTask: Task<Void, Never>?
    @ObservationIgnored private var proxyRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    /// TUN 的「关 → 换配置 → 重开」串行链（只保留最新意图）
    @ObservationIgnored private var tunReopenTask: Task<Void, Never>?

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

        self.settings = resolvedSettings
        self.kernel = resolvedKernel
        self.profiles = profileStore ?? ProfileStore(settings: resolvedSettings)
        self.systemProxy = systemProxy
        self.tun = tun ?? TunService(
            settings: resolvedSettings,
            systemProxy: systemProxy,
            kernel: resolvedKernel
        )
        self.proxies = ProxyService(kernel: resolvedKernel)
        self.traffic = TrafficService(kernel: resolvedKernel)
        self.connections = ConnectionService(kernel: resolvedKernel)
        self.logStore = LogStore(kernel: resolvedKernel)
        self.connectionState = systemProxy.isEnabled ? .on : .off

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

    /// 连接磁贴不可再点：内核启停中、系统代理正在写入、或 TUN 正在过渡
    var isConnectionBusy: Bool { kernel.isTransitioning || connectionState.isBusy || tun.isBusy }

    /// 状态条文案（§3.3）：内核 running + 代理关 = 已就绪，代理开 = 代理中。
    ///
    /// 连接磁贴只表示系统代理，内核由 App 生命周期管理，所以「代理关」不再是「未运行」。
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

    var pinnedGroups: [ProxyGroupModel] { proxies.pinnedGroups }
    var pinnedGroupIDs: Set<String> { Set(pinnedGroups.map(\.id)) }

    /// 空态文案：没配置「还没有配置」/ 有配置但内核没跑「内核未运行」/ 跑了但没组「当前配置没有策略组」
    var emptyGroupTitle: String {
        guard hasConfiguredProfile else { return "还没有配置" }
        if proxies.hasLoaded { return "当前配置没有策略组" }
        return phase == .failed ? "内核未运行" : "正在启动内核"
    }

    /// 已经导入订阅就不摆「导入订阅」按钮：用户不是没导入，只是内核还没就绪
    var showsEmptyGroupImportActions: Bool { !hasConfiguredProfile }

    /// 是否已有可用配置：订阅库有 active，或本次内核用了用户配置（DEBUG 的 `CLASH_PROFILE` 也算）
    private var hasConfiguredProfile: Bool { activeSubscription != nil || kernel.hasProfile }

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
                self.isGroupDataStale = false
                self.pruneRouteIfTargetMissing()
            }
            // 内核 running（含重启后新端口 / 新 secret）：重建 `/traffic` 连接
            traffic.start()
            // 内核 restart（更新订阅 / 开关 TUN 必经 stop→start）在 `.stopped` 里停了轮询；
            // 用户还停在连接页时要把轮询接回来，否则列表清空后再不刷新（只能退出页面重进）。
            if route == .connections {
                connections.startPolling()
            }
        case .stopped, .failed:
            // 相位变化不再清空策略组、不再重置路由：开关代理 / TUN / 更新订阅都会
            // 让内核 stop → start，清空只会让面板在开关瞬间塌成空态再长回来。
            // 保留最后一次快照，标记过期；`running` 后由 refresh 覆盖。
            proxyRefreshTask?.cancel()
            isGroupDataStale = true
            traffic.stop()
            connections.stopPolling()
            connections.clear()
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
    private func pruneRouteIfTargetMissing() {
        if let selectedGroupID,
           !proxies.allGroups.contains(where: { $0.id == selectedGroupID }) {
            self.selectedGroupID = nil
        }
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
            await self.systemProxy.restoreIfNeeded(kernelRunning: false)
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
    /// 新操作排在链尾；排队期间若又来了更新的操作，旧操作直接让位（只保留最新意图）。
    private func enqueueKernelOperation(_ operation: @escaping @MainActor () async -> Void) {
        kernelTaskID += 1
        let operationID = kernelTaskID
        let previous = kernelTask
        kernelTask = Task { [weak self] in
            await previous?.value
            guard let self, self.kernelTaskID == operationID else { return }
            await operation()
            if self.kernelTaskID == operationID { self.kernelTask = nil }
        }
    }

    // MARK: - 连接磁贴（系统代理总开关）

    /// 关闭 → 只还原系统代理（内核继续跑，节点仍可见可选）；开启 → 内核没跑先启动，再接管系统代理。
    /// 过渡中忽略点击。
    func toggleConnection() {
        // 内核过渡中：先说清原因（否则 isConnectionBusy 会静默吞掉这一下，用户以为点坏了）
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
        // 与 TUN 同理：内核过渡中调 `start()` 会被内部 guard 直接返回，
        // 再往下走只会拿到「内核未能就绪」这种误导文案。
        guard !kernel.isTransitioning else {
            connectionState = .off
            connectionError = "内核正在启动，请稍候"
            return
        }
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

    private func failConnection(_ stage: ConnectionState.Stage, error: Error) {
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
    var isApplyingSettings: Bool { kernel.isTransitioning || connectionState.isBusy }

    /// 「立即重启」：按新设置重建 runtime 并重启内核。
    ///
    /// 端口变了而系统代理还开着的话，代理会指向死端口：先撤代理，起来后按新端口重开。
    func restartKernelForSettings() {
        // TUN 内核由 helper 持有，本 App 既不能 stop 也不能按新设置重建：
        // 先关 → 用新设置重开（失败就停在关闭态，原因由 TUN banner 给）
        if tun.isHelperKernelRunning {
            reopenTunAfterConfigChange()
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

    /// 「完全清理…」：还原系统代理 → 停 TUN / 内核 → 删数据与偏好。
    ///
    /// 顺序与理由：
    /// 1. 系统代理必须先还原且**确认已关闭**（快照还在 = 代理仍指向本机端口），
    ///    否则删掉 runtime 会让用户对着死端口断网
    /// 2. TUN / 内核停不下来就中止：root 内核还在接管流量时删配置等于制造「黑盒断网」
    /// 3. 只删本 App 的用户数据与缓存、偏好；**不碰 `/Library/Application Support/ClashHelper`**
    ///    （root 目录由 helper 自己管，卸载入口在「组件」里）
    ///
    /// - Returns: `nil` 表示成功；否则是给用户看的中文失败原因。
    func performFullCleanup() async -> String? {
        // 0. 过渡中的任何一次系统代理写入都不能被删目录打断：
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

        // 3. 本地内核：`stop()` 在过渡中会静默返回，用相位复核一次
        await kernel.stop()
        if kernel.phase == .running || kernel.isExternal {
            return "内核未能停止，已中止清理"
        }

        // 4. 删目录：整个 App 数据根（settings.json / profiles / runtime / kernel / logs / 快照）
        let fileManager = FileManager.default
        let targets: [(String, URL)] = [
            ("应用数据", AppPaths.supportDirectory),
            ("缓存", AppPaths.cachesDirectory)
        ]
        for (name, url) in targets where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                return "删除\(name)失败：\(error.localizedDescription)"
            }
        }

        // 5. 偏好：UserDefaults 域 + plist 文件（存在才删）
        let bundleID = Bundle.main.bundleIdentifier ?? "com.clash.app"
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
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
        isGroupDataStale = false
        pruneRouteIfTargetMissing()
        connectionState = .off
        return nil
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

    // MARK: - TUN 磁贴（helper 安装 / 授权 / root 内核）
    //
    // 状态机与安装流程都在 `TunService` 里；这里只做转发与「与系统代理互斥」的编排。

    /// 磁贴五态（§4.2）：已关闭 / 需要授权 / 等待授权 / 已开启 / 失败
    var tunState: TunState { tun.tileState }
    /// 过渡 / 授权中：磁贴禁用，忽略重复点击
    var isTunBusy: Bool { tun.isBusy }
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

    /// 设置页（`docs/02-UI-SPEC.md` §4.9）：只改路由，保证 App 层（⚙ / ⌘, / 菜单项）
    /// 与面板内推入是同一个入口；面板是否已经叫出来由 App 层负责。
    func openSettingsPage() { route = .settings }

    /// 添加订阅页（§4.10）：进入时清掉上一次的失败文案
    func openSubscriptionNewPage() {
        importError = nil
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
        importError = nil

        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isImportingProfile = false }

            do {
                let entry = try await self.profiles.importURL(urlString)
                self.finishImport(entry)
                // 首次导入会自动激活：内核若在跑（用的是内置空配置）就重启一次
                if entry.id == self.profiles.activeProfileID {
                    self.restartKernelForProfileChange()
                }
            } catch {
                self.failImport(error)
            }
        }
    }

    /// UI 层（`NSOpenPanel`）选完文件后把 URL 交给 store
    func importLocalSubscription(fileURL: URL) {
        guard !isProfileBusy else { return }
        isImportingProfile = true
        importError = nil

        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isImportingProfile = false }

            do {
                let entry = try await self.profiles.importFile(at: fileURL)
                self.finishImport(entry)
                if entry.id == self.profiles.activeProfileID {
                    self.restartKernelForProfileChange()
                }
            } catch {
                self.failImport(error)
            }
        }
    }

    /// 导入成功：回到订阅列表（若还在添加页）并短暂高亮新项
    private func finishImport(_ entry: ProfileEntry) {
        importError = nil
        recentlyImportedProfileID = entry.id

        importHighlightTask?.cancel()
        importHighlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled else { return }
            self.recentlyImportedProfileID = nil
        }

        if route == .subscriptionNew {
            route = .subscriptions
        }
    }

    /// 导入失败：添加页内红字；从列表页发起时仍走原来的 3s 提示条
    private func failImport(_ error: Error) {
        let message = profileErrorMessage(error, fallback: "导入失败")
        importError = message

        if route != .subscriptionNew {
            showNotice(message)
        }
    }

    private func profileErrorMessage(_ error: Error, fallback: String) -> String {
        (error as? ProfileStoreError)?.userMessage ?? fallback
    }

    /// TUN 开着时换配置（订阅 / 端口 / 日志级别 / LAN）：先关 → 就地按新配置重开。
    ///
    /// 为什么不在关闭态就收手：TUN 是用户的显式意图，切个订阅就得重新点一次是坏体验。
    /// 为什么失败不重开：`TunService.enable()` 自己会在失败时回落本地内核并给 banner；
    /// 半关状态下重开只会在旧内核上叠一份新配置。
    private func reopenTunAfterConfigChange() {
        tunReopenTask?.cancel()
        tunReopenTask = Task { [weak self] in
            guard let self else { return }
            guard self.tun.isHelperKernelRunning else { return }

            await self.tun.disable(restartLocalKernel: false)
            guard !Task.isCancelled else { return }
            // 没关干净（stopKernel 失败）就不重开：那说明 root 内核还在接管流量
            guard !self.tun.isOn, !self.tun.isHelperKernelRunning else { return }

            await self.tun.enable()
        }
    }

    /// active 变了：先 stop 再 start，让 `KernelService` 按新 active 重建 runtime。
    /// 走同一条串行链，running 时也不会并发 start；内核没在跑（如自动启动失败）时也能救回来。
    private func restartKernelForProfileChange() {
        guard hasConfiguredProfile else {
            stopKernelForProfileChange()
            return
        }
        // TUN 内核里跑的是旧正文：关掉后按新 active 重开。
        // 只有「订阅确实切换成功」才会走到这里——拉取 / 校验失败时调用方不重启，
        // TUN 保持原状（旧配置仍然有效），不会出现「用旧配置接管新流量」的半套状态。
        if tun.isHelperKernelRunning {
            reopenTunAfterConfigChange()
            return
        }
        enqueueKernelOperation { [weak self] in
            guard let self else { return }
            await self.kernel.stop()
            await self.kernel.start()
        }
    }

    /// 库空了：先撤系统代理（撤不干净就保留内核，避免代理指向死端口），再停内核
    private func stopKernelForProfileChange() {
        // 配置全被删了：快照不再对应任何配置，这里必须清空（这不是「内核查相位变化」，
        // 而是路由 / 分组指向的对象真的不存在了）
        proxies.clear()
        isGroupDataStale = false
        pruneRouteIfTargetMissing()

        if tun.isHelperKernelRunning {
            Task { [weak self] in await self?.tun.disable() }
            return
        }
        enqueueKernelOperation { [weak self] in
            guard let self else { return }
            if self.isSystemProxyOn {
                do {
                    try await self.systemProxy.disable()
                    self.connectionState = .off
                } catch {
                    self.failConnection(.disable, error: error)
                    return
                }
            }
            await self.kernel.stop()
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

    /// Preview 夹具：摆出几张活动连接（不请求内核）
    func applyPreviewConnections() {
        connections.applyPreviewConnections()
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
