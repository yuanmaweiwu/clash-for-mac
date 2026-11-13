import SwiftUI

/// 订阅编辑面板的表单内容：一个输入框 + 取消 / 确认。
@MainActor
struct SubscriptionEditForm: View {
    let title: String
    let placeholder: String
    let confirmTitle: String
    let hint: String?
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(
        title: String,
        placeholder: String,
        confirmTitle: String,
        hint: String? = nil,
        initialText: String,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.hint = hint
        self.onConfirm = onConfirm
        self.onCancel = onCancel
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

            if let hint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            HStack(spacing: Space.m) {
                Spacer(minLength: 0)

                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button(confirmTitle) {
                    onConfirm(trimmed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320, height: 168, alignment: .topLeading)
    }
}
