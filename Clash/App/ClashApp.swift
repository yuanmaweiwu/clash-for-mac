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

    init() {
        #if DEBUG
        // CLI 自检入口（`CLASH_PROFILE_HARNESS` / `CLASH_PROXY_HARNESS`），正常启动不受影响
        ProfileStoreHarness.runIfRequested()
        SystemProxyHarness.runIfRequested()
        #endif
        _model = State(initialValue: PanelPreviewModel())
        Self.logger.info("Clash 启动（v0.2 系统代理）")
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

        Settings {
            SettingsPlaceholderView()
        }
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
