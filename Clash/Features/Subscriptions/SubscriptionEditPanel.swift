import AppKit
import SwiftUI

/// 极简输入面板：重命名订阅（普通改名，不承载导入——导入改在面板内「添加订阅」页）。
/// 只负责收文本；入库在 `ProfileStore`。
@MainActor
enum SubscriptionEditPanel {
    private static var current: NSPanel?

    static func showRename(current name: String, onSubmit: @escaping (String) -> Void) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 168),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "重命名订阅"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(
            rootView: SubscriptionEditForm(
                title: "重命名订阅",
                placeholder: "订阅名称",
                confirmTitle: "保存",
                initialText: name,
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
