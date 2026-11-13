import AppKit
import SwiftUI

/// 极简输入面板：导入订阅（URL）/ 重命名。只写本地假数据。
@MainActor
enum SubscriptionEditPanel {
    enum Mode {
        case url
        case rename(current: String)
    }

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
                onSubmit: onSubmit
            )
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private struct SubscriptionEditForm: View {
    let title: String
    let placeholder: String
    let confirmTitle: String
    let onSubmit: (String) -> Void

    @State private var text: String

    init(
        title: String,
        placeholder: String,
        confirmTitle: String,
        initialText: String,
        onSubmit: @escaping (String) -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.onSubmit = onSubmit
        _text = State(initialValue: initialText)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            Text("原型不联网，只写入本地假数据")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("取消") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.cancelAction)

                Button(confirmTitle) {
                    onSubmit(trimmed)
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320, height: 168, alignment: .topLeading)
    }
}
