import OSLog
import SwiftUI

/// App 组合根：状态栏浮层 + 设置窗口。
///
/// `PanelPreviewModel` 只服务 v0.1 的假数据演示；浮层与设置窗口共享同一实例，
/// 后续由 `KernelService` 支撑的真实模型替换。
@main
@MainActor
struct ClashApp: App {
    private static let logger = Logger(subsystem: "com.clash.app", category: "app")

    @State private var model = PanelPreviewModel()

    init() {
        Self.logger.info("Clash 启动（v0.1 面板）")
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

    /// 两态语义：未运行 = `power`，运行 = `power.circle.fill`，模板色随菜单栏。
    private var statusSymbolName: String {
        model.phase == .running ? "power.circle.fill" : "power"
    }

    private var phaseAccessibilityLabel: String {
        switch model.phase {
        case .running: "内核运行中"
        case .starting: "内核启动中"
        case .stopped: "内核已停止"
        case .failed: "内核启动失败"
        }
    }
}
