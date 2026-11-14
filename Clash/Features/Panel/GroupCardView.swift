import SwiftUI

/// 分组卡：卡头 32 + 三行节点 32 + 上下各 4pt 内边距 = 136pt，卡内不滚动、不画分隔线（§3.4 / §4.6）。
/// 选中项恒在首行，切换时整组三行交叉淡入（不整卡飞入）。
@MainActor
struct GroupCardView: View {
    let group: ProxyGroupModel
    /// 该组没被任何规则引用（§3.4）：卡头右侧提示，仅作说明，不影响选择
    let showsInactiveLabel: Bool
    let onOpen: () -> Void
    let onSelect: (String) -> Void

    @State private var isHeaderHovering = false
    @FocusState private var isHeaderFocused: Bool

    private var showsHeaderPill: Bool { isHeaderHovering }

    /// 卡头右侧：还有更多节点时显示剩余数，组内 ≤3 个时显示当前节点名（§3.4）
    private var headerTrailingText: String {
        if group.extraCount > 0 { return "还有 \(group.extraCount) 个" }
        return group.now ?? group.type
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            rows
                .id(group.cardOrderKey)
                .transition(.opacity)
        }
        .padding(.vertical, Metrics.cardInsetV)
        .animation(.easeInOut(duration: 0.18), value: group.cardOrderKey)
        .background {
            cardSurface
        }
    }

    /// 单层合成：填充 + 1pt 描边一起光栅化，避免圆角处的半透明过渡带
    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
            .fill(Theme.card)
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: Metrics.cardStroke)
            }
            .compositingGroup()
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(group.orderedNodes.enumerated()), id: \.element.id) { _, node in
                NodeRowView(
                    node: node,
                    isSelected: group.isSelected(node),
                    isAvailable: node.isAvailable,
                    action: { onSelect(node.id) }
                )
            }
        }
    }

    private var header: some View {
        Button(action: onOpen) {
            HStack(spacing: Space.xs) {
                Text(group.name)
                    .font(Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: Space.s)

                if showsInactiveLabel {
                    Text("未生效")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }

                Text(headerTrailingText)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 132, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: Metrics.cardHeaderHeight)
            .frame(maxWidth: .infinity)
            .background {
                if showsHeaderPill {
                    RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                        .fill(Theme.rowHover)
                        .padding(.horizontal, Metrics.pillInsetH)
                        .padding(.vertical, Metrics.pillInsetV)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .focused($isHeaderFocused)
        .focusEffectDisabled()
        .overlay {
            if isHeaderFocused {
                RoundedRectangle(cornerRadius: Metrics.radiusRow + 2, style: .continuous)
                    .strokeBorder(Theme.focus, lineWidth: 2)
                    .padding(-2)
            }
        }
        .onHover { isHeaderHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHeaderHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(cardAccessibilityLabel))
        .accessibilityHint("按下查看全部节点")
        .accessibilityAddTraits(.isButton)
    }

    /// 「未生效」必须读得出来：选中 / 数量之外先说状态，避免只看到节点名误以为在生效
    private var cardAccessibilityLabel: String {
        let status = showsInactiveLabel ? "，未生效" : ""
        if group.extraCount > 0 {
            return "\(group.name)\(status)，还有 \(group.extraCount) 个节点"
        }
        return "\(group.name)\(status)，当前 \(headerTrailingText)"
    }
}
