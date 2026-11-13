import AppKit
import SwiftUI

/// 日志窗口：唯一保留的独立窗口，由 AppKit 管理（不用 SwiftUI `Window` 场景）。
///
/// 用 `Window` 场景会在 App 启动时自动创建/恢复窗口，导致「一开机就弹出日志」；
/// 这里改成按需创建、单例复用，语义更接近菜单栏应用（`docs/adr/0011`）。
@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate {
    private let store: LogStore
    private let isTunMode: Bool

    init(store: LogStore, isTunMode: Bool) {
        self.store = store
        self.isTunMode = isTunMode

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "日志"
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.contentView = NSHostingView(
            rootView: LogWindowView(store: store, isTunMode: isTunMode)
        )
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持")
    }

    /// 显示并带到前台；已存在则只聚焦
    func present() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
