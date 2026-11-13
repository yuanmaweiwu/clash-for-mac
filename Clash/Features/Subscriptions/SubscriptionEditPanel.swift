import AppKit
import SwiftUI

/// 极简输入面板：导入订阅（URL）/ 重命名。
/// 只负责收文本；下载、校验、入库都在 `ProfileStore`。
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
        let hint: String?
        let initialText: String

        switch mode {
        case .url:
            title = "导入订阅"
            placeholder = "订阅链接（https://…）"
            confirmTitle = "导入"
            hint = "导入前会用内核校验配置；失败不会留下半截文件"
            initialText = ""
        case .rename(let current):
            title = "重命名订阅"
            placeholder = "订阅名称"
            confirmTitle = "保存"
            hint = nil
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
                hint: hint,
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
