import SwiftUI

/// 全部策略组的一行 48pt（两行：组名 + 节点数）：hover / 当前组用同一套胶囊，
/// 当前组只加粗 + 底色，不加 ✓；星标控制是否固定到首屏（主组禁用）。
@MainActor
struct AllGroupsRowView: View {
    let group: DemoGroup
    let isActive: Bool
    let onTogglePin: () -> Void
    let onOpen: () -> Void
    /// 原型调试：强制 hover（离屏快照用）
    var forcedHover = false

    @State private var isHovering = false
    @FocusState private var isStarFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(isActive ? Typography.title : Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(group.nodes.count) 个节点")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 6)

            starButton
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .background {
            if isActive || isHovering || forcedHover {
                RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                    .fill(isActive ? Theme.rowSelected : Theme.rowHover)
                    .padding(.horizontal, Metrics.pillInsetH)
                    .padding(.vertical, Metrics.listPillInsetV)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovering)
        .animation(.easeInOut(duration: 0.18), value: isActive)
    }

    private var starButton: some View {
        Button(action: onTogglePin) {
            Image(systemName: group.isPinned ? "star.fill" : "star")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(starColor)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(group.isMainGroup)
        .focused($isStarFocused)
        .focusEffectDisabled()
        .overlay {
            if isStarFocused {
                RoundedRectangle(cornerRadius: Metrics.radiusRow + 1, style: .continuous)
                    .strokeBorder(Theme.focus, lineWidth: 2)
                    .padding(-1)
            }
        }
        .help(group.isMainGroup ? "主组固定显示" : (group.isPinned ? "取消固定" : "固定到首屏"))
        .accessibilityLabel(Text(group.isPinned ? "取消固定 \(group.name)" : "固定 \(group.name)"))
    }

    private var starColor: Color {
        if group.isMainGroup { return Theme.textTertiary }
        return group.isPinned ? Theme.accent : Theme.textSecondary
    }
}
