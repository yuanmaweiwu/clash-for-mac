import AppKit
import SwiftUI

/// 还没做的入口统一用这个占位面板，避免编造内容。
@MainActor
enum PlaceholderPanel {
    private static var current: NSPanel?

    static func show(title: String, detail: String) {
        current?.close()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(
            rootView: PlaceholderView(title: title, detail: detail)
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        current = panel
    }
}

@MainActor
private struct PlaceholderView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text("原型未实现")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 300, height: 150, alignment: .topLeading)
    }
}
