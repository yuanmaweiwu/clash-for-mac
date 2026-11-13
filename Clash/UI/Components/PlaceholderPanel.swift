import AppKit
import SwiftUI

/// 尚未实现的入口统一用这个占位窗口，避免编造内容。
@MainActor
enum PlaceholderPanel {
    private static var current: NSPanel?

    static func show(title: String, detail: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(
            rootView: PlaceholderPanelContentView(title: title, detail: detail)
        )
        panel.center()

        current?.close()
        current = panel

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
