import AppKit
import SwiftUI

/// 极简输入面板：导入订阅（URL）/ 重命名。
/// v0.1 只写面板假数据，不联网；真实订阅库由 v0.2 的订阅服务接。
@MainActor
enum SubscriptionEditPanel {
    enum Mode {
        case url
        case rename(current: String)
    }

    private static var current: NSPanel?

    static func show(mode: Mode, onSubmit: @escaping (String) -> Void) {
        let title: String
        let placeholder: String
        let confirmTitle: String
        let initialText: String

        switch mode {
        case .url:
            title = "导入订阅"
            placeholder = "订阅链接（https://…）"
            confirmTitle = "导入"
            initialText = ""
        case .rename(let current):
            title = "重命名订阅"
            placeholder = "订阅名称"
            confirmTitle = "保存"
            initialText = current
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 168),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(
            rootView: SubscriptionEditForm(
                title: title,
                placeholder: placeholder,
                confirmTitle: confirmTitle,
                initialText: initialText,
                onConfirm: { [weak panel] text in
                    onSubmit(text)
                    panel?.close()
                },
                onCancel: { [weak panel] in panel?.close() }
            )
        )
        panel.center()

        current?.close()
        current = panel

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
