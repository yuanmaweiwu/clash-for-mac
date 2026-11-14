import SwiftUI

/// 全部策略组的一行 48pt（两行：组名 + 节点数）：hover / 当前组用同一套胶囊，
/// 当前组只加粗 + 底色，不加 ✓；星标控制是否固定到首屏（主组禁用）。
///
/// 整行是按钮（键盘可 Tab、可 Space 触发、有焦点环）；星标叠在行尾，自己也是一个按钮。
@MainActor
struct AllGroupsRowView: View {
    let group: ProxyGroupModel
    let isActive: Bool
    /// 该组没有被任何规则引用（§4.7）：行尾提示，仅作说明，不影响 pin 与选择
    let showsInactiveLabel: Bool
    let onTogglePin: () -> Void
    let onOpen: () -> Void

    @State private var isHovering = false
    @FocusState private var isRowFocused: Bool
    @FocusState private var isStarFocused: Bool

    var body: some View {
        Button(action: onOpen) {
            rowBody
        }
        .buttonStyle(PressableButtonStyle())
        .focused($isRowFocused)
        .focusEffectDisabled()
        .accessibilityLabel(Text(group.name))
        .accessibilityValue(Text(showsInactiveLabel
            ? "\(group.nodes.count) 个节点，未生效"
            : "\(group.nodes.count) 个节点"))
        .accessibilityHint(Text("按下查看节点"))
        .overlay {
            if isRowFocused {
                RoundedRectangle(cornerRadius: Metrics.radiusRow + 2, style: .continuous)
                    .strokeBorder(Theme.focus, lineWidth: 2)
                    .padding(-2)
            }
        }
        .overlay(alignment: .trailing) {
            starButton
                .padding(.trailing, Space.s)
        }
        .frame(height: Metrics.listRowHeight)
        .background { rowBackground }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovering)
        .animation(.easeInOut(duration: 0.18), value: isActive)
    }

    /// 文字区右侧给星标留 28pt 热区 + 6pt 呼吸
    private var rowBody: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(group.name)
                    .font(isActive ? Typography.title : Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(group.nodes.count) 个节点")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: Space.s)

            if showsInactiveLabel {
                Text("未生效")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.leading, Metrics.cardPadding)
        .padding(.trailing, Metrics.cardPadding + Metrics.hitTarget)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isActive || isHovering {
            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                .fill(isActive ? Theme.rowSelected : Theme.rowHover)
                .padding(.horizontal, Metrics.pillInsetH)
                .padding(.vertical, Metrics.listPillInsetV)
        }
    }

    private var starButton: some View {
        Button(action: onTogglePin) {
            Image(systemName: group.isPinned ? "star.fill" : "star")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(starColor)
                .frame(width: Metrics.hitTarget, height: Metrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!group.canPin)
        .focused($isStarFocused)
        .focusEffectDisabled()
        .overlay {
            if isStarFocused {
                RoundedRectangle(cornerRadius: Metrics.radiusRow + 1, style: .continuous)
                    .strokeBorder(Theme.focus, lineWidth: 2)
                    .padding(-1)
            }
        }
        .help(starHelp)
        .accessibilityLabel(Text(group.isPinned ? "取消固定 \(group.name)" : "固定 \(group.name)"))
    }

    /// 未生效组固定了也不会上首屏（首屏只收生效组）；提示说清楚，避免用户以为星标失灵
    private var starHelp: String {
        guard group.canPin else { return "主组固定显示" }
        if showsInactiveLabel { return "该组未被规则引用，不会出现在首屏" }
        return group.isPinned ? "取消固定" : "固定到首屏"
    }

    private var starColor: Color {
        if !group.canPin { return Theme.textTertiary }
        return group.isPinned ? Theme.accent : Theme.textSecondary
    }
}
