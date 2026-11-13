import OSLog
import SwiftUI

/// App 组合根：状态栏浮层 + 设置窗口占位。
@main
@MainActor
struct ClashApp: App {
    private static let logger = Logger(subsystem: "com.clash.app", category: "app")

    /// 内核运行状态占位：接入 `KernelService` 后由真实状态替换。
    @State private var isKernelRunning = false

    init() {
        Self.logger.info("Clash 启动（v0.1 骨架）")
    }

    var body: some Scene {
        MenuBarExtra {
            PanelPlaceholderView()
        } label: {
            Image(systemName: isKernelRunning ? "power.circle.fill" : "power")
                .renderingMode(.template)
                .accessibilityLabel(isKernelRunning ? "内核运行中" : "内核已停止")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsPlaceholderView()
        }
    }
}

/// 设置窗口占位：接入 `Features/Settings` 后替换。
@MainActor
private struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("设置待实现")
                .font(.headline)
            Text("v0.1 骨架，暂无设置项")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 420, height: 240)
    }
}
