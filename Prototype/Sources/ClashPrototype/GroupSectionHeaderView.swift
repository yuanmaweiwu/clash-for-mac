import SwiftUI

/// 区块标题 20pt：`font/section` + 右侧「全部 ›」（§3.2）。
@MainActor
struct GroupSectionHeaderView: View {
    let onOpenAll: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("策略组")
                .font(Typography.section)
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: 6)

            Button(action: onOpenAll) {
                HStack(spacing: 4) {
                    Text("全部")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                        .strokeBorder(Theme.focus, lineWidth: 2)
                        .padding(-2)
                }
            }
            .accessibilityLabel(Text("全部策略组"))
            .accessibilityAddTraits(.isButton)
        }
        .frame(height: Metrics.groupTitleHeight, alignment: .top)
    }
}
