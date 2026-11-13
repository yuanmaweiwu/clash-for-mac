import AppKit
import OSLog
import SwiftUI

/// App 组合根：状态栏浮层 + 设置窗口。
///
/// 面板模型与菜单栏图标共享同一实例；model 在 harness 之后创建，
/// 避免自检流程与「启动兜底还原系统代理」抢同一份快照。
@main
@MainActor
struct ClashApp: App {
    private static let logger = Logger(subsystem: "com.clash.app", category: "app")

    @State private var model: PanelPreviewModel
    /// 设置窗口与面板共用同一份设置
    @State private var settings: SettingsStore

    /// 退出清理：`applicationWillTerminate` 与 `SIGTERM` / `SIGINT` / `SIGHUP` 共用一份实现
    private let terminationGuard: AppTerminationGuard

    init() {
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
        // 设置只建一份：内核注入端口 / 面板开代理 / 设置窗口写偏好都指向同一实例
        let settings = SettingsStore()
        // 服务先于 model / guard 建好：两者共享同一实例，退出清理才看得见真实状态
        let systemProxy = SystemProxyService()
        let kernel = KernelService(settings: settings)
        // TUN 与面板、退出清理共享同一实例：退出清理必须看得见「TUN 是否开着」
        let tun = TunService(settings: settings, systemProxy: systemProxy, kernel: kernel)
        _model = State(initialValue: PanelPreviewModel(
            kernel: kernel,
            systemProxy: systemProxy,
            settings: settings,
            tun: tun,
            autoStartsKernel: smokeMode == nil
        ))
        _settings = State(initialValue: settings)
        terminationGuard = AppTerminationGuard(kernel: kernel, systemProxy: systemProxy, tun: tun)
        Self.logger.info("Clash 启动（v0.2 系统代理 + TUN）")

        #if DEBUG
        if let smokeMode {
            TunSmokeHarness.startIfRequested(
                mode: smokeMode,
                settings: settings,
                systemProxy: systemProxy,
                kernel: kernel,
                tun: tun
            )
        }
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model, onClose: PopoverCloser.close)
        } label: {
            Image(systemName: statusSymbolName)
                .renderingMode(.template)
                .accessibilityLabel(phaseAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
        .commands {
            SettingsCommands()
        }

        // 日志窗口：单例（`Window` 重复 openWindow 只聚焦已有窗口），不是二级面板
        Window("日志", id: AppWindow.logsID) {
            LogWindowView(store: model.logStore, isTunMode: model.isTunOn)
        }
        .defaultSize(width: 760, height: 520)
        .defaultPosition(.center)

        // 设置窗口：独立单例窗口（`docs/02-UI-SPEC.md` §8.7），不承载日常操作
        Window("设置", id: AppWindow.settingsID) {
            SettingsWindowView(model: model, settings: settings)
        }
        .defaultSize(width: 640, height: 520)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }

    /// 图标语义只有一个：**是否正在接管流量**（§4.1）。
    /// 代理中 = 实心；其余（未运行 / 已就绪 / 直连 / 失败）= 描边。
    private var statusSymbolName: String {
        model.isSystemProxyOn ? "power.circle.fill" : "power"
    }

    private var phaseAccessibilityLabel: String {
        model.status.title
    }
}

/// 独立窗口的 id（`openWindow(id:)` 与 `Window(id:)` 必须一致）
enum AppWindow {
    static let logsID = "logs"
    static let settingsID = "settings"
}

/// ⌘, 打开设置：`Window` 场景不会自动生成「设置…」菜单项，这里自己补一条
@MainActor
private struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                openWindow(id: AppWindow.settingsID)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
