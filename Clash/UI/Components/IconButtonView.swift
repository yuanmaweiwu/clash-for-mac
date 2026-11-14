import SwiftUI

/// 图标按钮：28pt 热区、16pt 视觉、hover 底、无描边（§2.7 `size/hit`）。
@MainActor
struct IconButtonView: View {
    let systemName: String
    let label: String
    var iconSize: CGFloat = 13
    /// 静止色（默认 `text/secondary`）；需要更弱一档时传 `text/tertiary`
    var restingTint: Color?
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(isHovering ? Theme.textPrimary : (restingTint ?? Theme.textSecondary))
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                        .fill(isHovering ? Theme.rowHover : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .focused($isFocused)
        .focusEffectDisabled()
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Metrics.radiusRow + 1, style: .continuous)
                    .strokeBorder(Theme.focus, lineWidth: 2)
                    .padding(-1)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(.isButton)
    }
}
