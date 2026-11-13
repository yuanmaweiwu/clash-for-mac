import AppKit
import SwiftUI

/// App 组合根：场景只剩「日志」窗口。
///
/// 状态栏图标 + 面板由 `AppDelegate` 创建的 `StatusItemController` 持有（`docs/adr/0011`），
/// 面板里的设置、添加订阅都是面板内页面；它们共用同一份 `AppEnvironment.model`。
@main
@MainActor
struct ClashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var model: PanelPreviewModel

    init() {
        // 服务、模型、面板、退出清理都在组合根里建好；这里只取引用
        _model = State(initialValue: AppEnvironment.shared.model)
    }

    var body: some Scene {
        // 没有任何需要 SwiftUI 管理的窗口：状态栏与面板由 AppKit 持有，
        // 日志窗口由 `LogWindowController` 按需创建（避免启动即弹出）。
        // `Settings` 场景本身不会创建窗口，仅用于满足 App 至少一个 Scene 的要求。
        Settings {
            EmptyView()
        }
    }
}
