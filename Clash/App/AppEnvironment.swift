import AppKit
import OSLog

/// App 组合根：服务、面板模型、面板窗口、退出清理只建一份，SwiftUI `App` 与 `AppDelegate` 共享。
///
/// 状态栏图标由 `StatusItemController`（AppKit）持有，面板内容仍是同一份 `PanelView`，
/// 所以模型不能跟着某个 `Scene` 走，必须放在场景之外的单例里。
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    private static let logger = Logger(subsystem: "com.clash.app", category: "app")

    /// 设置只建一份：内核注入端口 / 面板开代理 / 设置页写偏好都指向同一实例
    let settings: SettingsStore
    /// 真实内核生命周期
    let kernel: KernelService
    /// 真实系统代理（快照落盘 + 逐服务还原）
    let systemProxy: SystemProxyService
    /// TUN 与面板、退出清理共享同一实例
    let tun: TunService
    /// 面板模型（`PanelView` 的唯一数据入口）
    let model: PanelPreviewModel
    /// 退出清理：`applicationWillTerminate` 与 `SIGTERM` / `SIGINT` / `SIGHUP` 共用一份实现
    let terminationGuard: AppTerminationGuard
    /// 控制面板窗口（常驻，显隐由状态栏图标 / 菜单项控制）
    let panel: PanelWindowController

    /// 面板锚点：状态栏按钮装在 `StatusItemController` 里，由它把取按钮的方式交过来
    var statusItemAnchor: (() -> NSStatusBarButton?)?

    private var logWindow: LogWindowController?

    private init() {
        #if DEBUG
        // CLI 自检入口（`CLASH_PROFILE_HARNESS` / `CLASH_PROXY_HARNESS`），正常启动不受影响
        ProfileStoreHarness.runIfRequested()
        SystemProxyHarness.runIfRequested()
        LogStoreHarness.runIfRequested()
        SettingsHarness.runIfRequested()
        KernelSettingsHarness.runIfRequested()
        TunConfigHarness.runIfRequested()
        #endif
        #if DEBUG
        // 真机 TUN 自检（会真的起 root 内核）：命中时不让面板自动起本地内核，避免抢端口
        let smokeMode = TunSmokeHarness.requestedMode()
        #else
        let smokeMode: String? = nil
        #endif
        // 服务先于 model / guard 建好：两者共享同一实例，退出清理才看得见真实状态
        let settings = SettingsStore()
        let systemProxy = SystemProxyService()
        let kernel = KernelService(settings: settings)
        let tun = TunService(settings: settings, systemProxy: systemProxy, kernel: kernel)
        let model = PanelPreviewModel(
            kernel: kernel,
            systemProxy: systemProxy,
            settings: settings,
            tun: tun,
            autoStartsKernel: smokeMode == nil
        )
        self.settings = settings
        self.systemProxy = systemProxy
        self.kernel = kernel
        self.tun = tun
        self.model = model
        panel = PanelWindowController(model: model)
        terminationGuard = AppTerminationGuard(
            kernel: kernel,
            systemProxy: systemProxy,
            tun: tun,
            settings: settings
        )
        Self.logger.info("Clash 启动（v0.2 系统代理 + TUN）")

        #if DEBUG
        if let smokeMode {
            TunSmokeHarness.startIfRequested(
                mode: smokeMode,
                systemProxy: systemProxy,
                kernel: kernel,
                tun: tun,
                model: model
            )
        }
        #endif
    }

    // MARK: - 面板入口（状态栏左键 / 右键菜单 / ⌘, 共用）

    /// 确保面板显示；已显示就不动（不 toggle）
    func showPanel() {
        guard !panel.isVisible else { return }
        panel.show(relativeTo: statusItemAnchor?())
    }

    /// ⌘, 与右键菜单「设置…」：面板显示 + 推入设置页（同一入口，避免两套状态）
    func showSettingsPage() {
        showPanel()
        model.openSettingsPage()
    }

    // MARK: - 日志窗口（唯一保留的独立窗口）

    /// 打开日志窗口（单例）并带到前台；LSUIElement 应用不激活就看不见新窗口
    func openLogsWindow() {
        if logWindow == nil {
            logWindow = LogWindowController(store: model.logStore, isTunMode: model.isTunOn)
        }
        logWindow?.present()
    }
}
