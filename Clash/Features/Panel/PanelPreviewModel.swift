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
///
/// **还没接的**：设置窗口、TUN（helper）。
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
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var speedTask: Task<Void, Never>?
    @ObservationIgnored private var speedNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var speedFlashTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var modeTask: Task<Void, Never>?
    @ObservationIgnored private var proxyRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?

    init(
        kernel: KernelService? = nil,
        profileStore: ProfileStore? = nil,
        systemProxy: SystemProxyService = SystemProxyService(),
        settings: SettingsStore? = nil,
        autoStartsKernel: Bool = true
    ) {
        // 设置只允许一份实例：内核注入端口 / 模型读端口 / 设置窗口写端口必须是同一个对象
        let resolvedSettings = settings ?? kernel?.settings ?? SettingsStore()
        let resolvedKernel = kernel ?? KernelService(settings: resolvedSettings)

        self.settings = resolvedSettings
        self.kernel = resolvedKernel
        self.profiles = profileStore ?? ProfileStore(settings: resolvedSettings)
        self.systemProxy = systemProxy
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

    /// 内核版本（`/version` 的 `version` 字段）；未运行时为 nil
    var kernelVersion: String? { kernel.kernelVersion }

    /// 连接磁贴不可再点：内核启停中，或系统代理正在写入
    var isConnectionBusy: Bool { kernel.isTransitioning || connectionState.isBusy }

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

    /// 已经导入订阅就不摆「导入订阅 / 选择 YAML」：用户不是没导入，只是内核还没就绪
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
            // 内核 running（含重启后新端口 / 新 secret）：重建 `/traffic` 连接
            traffic.start()
        case .stopped, .failed:
            // 组数据作废：二级页的目标可能已经不在了，先回首层，避免空白面板
            proxyRefreshTask?.cancel()
            proxies.clear()
            traffic.stop()
            connections.stopPolling()
            connections.clear()
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

    /// 「完全清理…」：还原系统代理 → 停内核 → 删 `profiles/` `runtime/` `kernel/` `logs/` 与代理快照。
    /// **不删 App 本身**，也不动 `settings.json`（否则窗口里的偏好会突然回默认）。
    /// - Returns: `nil` 表示成功；否则是给用户看的中文失败原因。
    func performFullCleanup() async -> String? {
        if isSystemProxyOn {
            do {
                try await systemProxy.disable()
                connectionState = .off
            } catch {
                let message = systemProxy.lastError?.userMessage ?? "还原系统代理失败"
                return "\(message)，已中止清理"
            }
        }

        await kernel.stop()
        profiles.forgetAllAfterCleanup()

        let fileManager = FileManager.default
        let targets: [(String, URL)] = [
            ("profiles", AppPaths.profilesDirectory),
            ("runtime", AppPaths.runtimeDirectory),
            ("kernel", AppPaths.kernelDirectory),
            ("logs", AppPaths.logsDirectory),
            ("代理快照", AppPaths.systemProxySnapshotURL)
        ]
        for (name, url) in targets where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                return "删除\(name)失败：\(error.localizedDescription)"
            }
        }

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

    // MARK: - TUN 磁贴
    //
    // v0.1 没有 helper / root 权限（ADR-0007），TUN 不可用，也不做假开关：
    // 磁贴恒为灰态「需要管理员组件」，点击只解释原因（见 `ControlGridView`）。

    // MARK: - 导航

    func openAllGroups() { route = .allGroups }
    func openSubscriptions() { route = .subscriptions }
    func openConnections() { route = .connections }
    func popToRoot() {
        connections.stopPolling()
        route = .root
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

    /// active 变了：先 stop 再 start，让 `KernelService` 按新 active 重建 runtime。
    /// 走同一条串行链，running 时也不会并发 start；内核没在跑（如自动启动失败）时也能救回来。
    private func restartKernelForProfileChange() {
        guard hasConfiguredProfile else {
            stopKernelForProfileChange()
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
