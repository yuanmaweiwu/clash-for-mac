import SwiftUI

/// 区块标题 28pt：`font/section` + 右侧「全部 ›」（§3.2）。
///
/// 标题本身不是控件；右侧入口有 28pt 命中区，hover 时文字转正文色。
@MainActor
struct GroupSectionHeaderView: View {
    let onOpenAll: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Space.xs) {
            Text("策略组")
                .font(Typography.section)
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: Space.s)

            Button(action: onOpenAll) {
                HStack(spacing: Space.xs) {
                    Text("全部")
                        .font(Typography.caption)
                        .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, Space.xs)
                .frame(height: Metrics.hitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                        .strokeBorder(Theme.focus, lineWidth: 2)
                        .padding(-2)
                }
            }
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .accessibilityLabel(Text("全部策略组"))
            .accessibilityAddTraits(.isButton)
        }
        .frame(height: Metrics.groupTitleHeight)
    }
}
