import SwiftUI

/// 可点磁贴：`TilePanel` 视觉 + 按钮语义（按下 0.98、hover、焦点环）。
@MainActor
struct TileShell<Content: View>: View {
    private let action: () -> Void
    private let border: Color?
    private let label: String
    private let value: String
    private let content: Content

    @FocusState private var isFocused: Bool

    init(
        border: Color? = nil,
        label: String,
        value: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.border = border
        self.label = label
        self.value = value
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            TilePanel(border: border, isHoverable: true) {
                content
            }
        }
        .buttonStyle(PressableButtonStyle())
        .focused($isFocused)
        .focusEffectDisabled()
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Metrics.radiusCard + 2, style: .continuous)
                    .strokeBorder(Theme.focus, lineWidth: 2)
                    .padding(-2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
        .accessibilityAddTraits(.isButton)
    }
}
