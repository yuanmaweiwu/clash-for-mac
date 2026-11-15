import Foundation
import Observation
import OSLog

/// 订阅写操作的宿主：只提供「面板 UI 状态怎么改」的几个入口，
/// `SubscriptionActions` 不反向依赖 `PanelPreviewModel`。
@MainActor
protocol SubscriptionActionsHost: AnyObject {
    /// 是否有可运行配置（active 订阅或内核已有正文）
    var hasConfiguredProfile: Bool { get }
    /// 我们是否正在接管系统代理
    var isSystemProxyOn: Bool { get }
    /// 内核 start / stop 串行链（只保留最新意图）
    func enqueueKernelOperation(_ operation: @escaping @MainActor () async -> Void)
    /// 订阅相关操作已把系统代理还原成功
    func subscriptionActionsProxyTurnedOff()
    /// 订阅相关操作还原系统代理失败
    func subscriptionActionsProxyFailed(_ error: Error)
    /// 配置库被清空：策略组快照作废、路由指向不存在的目标要退回
    func subscriptionActionsProfilesCleared()
    /// 热重载成功：内核相位没变（TUN 场景），面板需要主动刷新一次 `/proxies`
    func subscriptionActionsDidReloadProxies()
    /// 导入成功：若还停在「添加订阅」页就回到列表
    func subscriptionActionsDidImport()
    /// 导入失败：页内红字由本类自己写，这里只处理「不在添加页时」的提示条
    func subscriptionActionsImportFailed(_ message: String)
}

/// 订阅库的写操作编排：切换 / 更新 / 重命名 / 删除 / 导入，以及随之而来的内核重启。
///
/// 依赖 `ProfileStore` / `KernelService` / `TunService` / `SystemProxyService`（构造注入），
/// UI 状态（更新中 / 导入中 / 导入错误 / 高亮 / 3s 提示）也归本类；`PanelPreviewModel`
/// 只做同名转发，View 不需要改。
@MainActor
@Observable
final class SubscriptionActions {

    /// 正在更新 / 导入的那一条（行里显示「更新中」）
    private(set) var updatingProfileID: String?
    private(set) var isImportingProfile = false
    /// 「添加订阅」页的失败文案：留在页内（输入框下的红字），不弹窗、不进 banner
    private(set) var importError: String?
    /// 刚导入成功的那一条：回到订阅列表时短暂高亮
    private(set) var recentlyImportedProfileID: String?
    /// 列表顶部 3s 提示条
    private(set) var notice: String?

    private static let logger = Logger(subsystem: "com.clash.app", category: "subscriptions")

    @ObservationIgnored private let profiles: ProfileStore
    @ObservationIgnored private let kernel: KernelService
    @ObservationIgnored private let systemProxy: SystemProxyService
    @ObservationIgnored private let tun: TunService
    @ObservationIgnored private weak var host: SubscriptionActionsHost?

    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var importHighlightTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// TUN 的「关 → 换配置 → 重开」串行链（只保留最新意图）
    @ObservationIgnored private var tunReopenTask: Task<Void, Never>?

    init(
        profiles: ProfileStore,
        kernel: KernelService,
        systemProxy: SystemProxyService,
        tun: TunService
    ) {
        self.profiles = profiles
        self.kernel = kernel
        self.systemProxy = systemProxy
        self.tun = tun
    }

    /// 宿主在自身初始化末尾接入（弱引用，不构成环）
    func attach(host: SubscriptionActionsHost) {
        self.host = host
    }

    /// 一次只跑一个订阅写操作：索引是共享状态，避免更新中被删 / 被切换
    private var isProfileBusy: Bool { updatingProfileID != nil || isImportingProfile }

    // MARK: - 切换 / 更新 / 重命名 / 删除

    func activate(_ id: String) {
        guard !isProfileBusy else { return }
        do {
            guard try profiles.activate(id: id) == .switched else { return }
            // 切换 = 换 active + 重建 runtime + 重载；v0.3 用 stop → start 等效
            restartKernelForProfileChange()
        } catch {
            showNotice(profileErrorMessage(error, fallback: "切换失败"))
        }
    }

    func update(_ id: String) {
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

    func rename(_ id: String, to newName: String) {
        guard !isProfileBusy else { return }
        do {
            try profiles.rename(id: id, to: newName)
        } catch {
            showNotice(profileErrorMessage(error, fallback: "重命名失败"))
        }
    }

    func delete(_ id: String) {
        guard !isProfileBusy, let removed = profiles.entry(id: id) else { return }
        do {
            switch try profiles.delete(id: id) {
            case .cleared:
                showNotice("已删除「\(removed.name)」，将停止内核")
                stopKernelForProfileChange()
            case .switched:
                let next = profiles.activeProfile?.name ?? "另一条"
                showNotice("已删除「\(removed.name)」，已切换到「\(next)」")
                restartKernelForProfileChange()
            case .none:
                break
            }
        } catch {
            showNotice(profileErrorMessage(error, fallback: "删除失败"))
        }
    }

    // MARK: - 导入

    func importURL(_ urlString: String) {
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
    func importFile(at fileURL: URL) {
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

    /// 进入「添加订阅」页时清掉上一次的失败文案
    func clearImportError() {
        importError = nil
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

        host?.subscriptionActionsDidImport()
    }

    /// 导入失败：添加页内红字；从列表页发起时仍走原来的 3s 提示条
    private func failImport(_ error: Error) {
        let message = profileErrorMessage(error, fallback: "导入失败")
        importError = message
        host?.subscriptionActionsImportFailed(message)
    }

    private func profileErrorMessage(_ error: Error, fallback: String) -> String {
        (error as? ProfileStoreError)?.userMessage ?? fallback
    }

    // MARK: - 内核重启 / 停止

    /// TUN 开着时换配置（订阅 / 端口 / 日志级别 / LAN）：先关 → 就地按新配置重开。
    ///
    /// 为什么不在关闭态就收手：TUN 是用户的显式意图，切个订阅就得重新点一次是坏体验。
    /// 为什么失败不重开：`TunService.enable()` 自己会在失败时回落本地内核并给 banner；
    /// 半关状态下重开只会在旧内核上叠一份新配置。
    func reopenTunAfterConfigChange() {
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

    /// active 变了：优先热重载（重建 runtime → `PUT /configs`），失败才回退 stop → start。
    ///
    /// - 本地内核：复用当前端口 / secret / DNS 端口，进程与 pid 不变
    /// - TUN：新正文先经 helper 落盘，再对当前 controller 发同一个请求；pid / utun 必须不变
    /// 走同一条串行链，running 时也不会并发 start；内核没在跑（如自动启动失败）时也能救回来。
    private func restartKernelForProfileChange() {
        guard host?.hasConfiguredProfile == true else {
            stopKernelForProfileChange()
            return
        }
        // TUN 内核里跑的是旧正文：热重载失败再回退 disable + enable。
        // 只有「订阅确实切换成功」才会走到这里——拉取 / 校验失败时调用方不重启，
        // TUN 保持原状（旧配置仍然有效），不会出现「用旧配置接管新流量」的半套状态。
        if tun.isHelperKernelRunning {
            reloadTunForProfileChange()
            return
        }
        host?.enqueueKernelOperation { [weak self] in
            guard let self else { return }
            do {
                try await self.kernel.reloadProfile()
            } catch {
                // 已被更新的意图取代：让新操作接手，旧任务不做回退（避免连切时多跑一轮 stop→start）
                guard !Task.isCancelled else { return }
                Self.logger.error(
                    "本地内核热重载失败，回退 stop→start：\(String(describing: error), privacy: .public)"
                )
                await self.kernel.stop()
                // 切订阅比 stop 还快：已经有人排了更新的意图，就别再拉起旧配置。
                // 250ms 合并窗口：0.2s 连切时把中间选择全部折叠掉，只按最后一次启动
                // （窗口内被取消 → 直接让位，一次真实 `kernel.start()` 都不跑）。
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.kernel.start()
            }
        }
    }

    /// TUN：先热重载，失败（或本来就没到 `.on`）再走原来的 disable + enable。
    private func reloadTunForProfileChange() {
        tunReopenTask?.cancel()
        tunReopenTask = Task { [weak self] in
            guard let self else { return }
            guard self.tun.isHelperKernelRunning else { return }

            if self.tun.isOn {
                do {
                    try await self.tun.reloadProfile()
                    self.host?.subscriptionActionsDidReloadProxies()
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    Self.logger.error(
                        "TUN 热重载失败，回退 disable+enable：\(String(describing: error), privacy: .public)"
                    )
                }
            }

            await self.tun.disable(restartLocalKernel: false)
            guard !Task.isCancelled else { return }
            // 没关干净（stopKernel 失败）就不重开：那说明 root 内核还在接管流量
            guard !self.tun.isOn, !self.tun.isHelperKernelRunning else { return }

            await self.tun.enable()
        }
    }

    /// 库空了：先撤系统代理（撤不干净就保留内核，避免代理指向死端口），再停内核
    private func stopKernelForProfileChange() {
        // 配置全被删了：快照不再对应任何配置，这里必须清空（这不是「内核查相位变化」，
        // 而是路由 / 分组指向的对象真的不存在了）
        host?.subscriptionActionsProfilesCleared()

        if tun.isHelperKernelRunning {
            Task { [weak self] in await self?.tun.disable() }
            return
        }
        host?.enqueueKernelOperation { [weak self] in
            guard let self else { return }
            if self.host?.isSystemProxyOn == true {
                do {
                    try await self.systemProxy.disable()
                    self.host?.subscriptionActionsProxyTurnedOff()
                } catch {
                    self.host?.subscriptionActionsProxyFailed(error)
                    return
                }
            }
            await self.kernel.stop()
        }
    }

    // MARK: - 提示条

    /// 列表顶部 3s 提示条（导入失败等 `failImport` 也会用）
    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.notice = nil
        }
    }
}
