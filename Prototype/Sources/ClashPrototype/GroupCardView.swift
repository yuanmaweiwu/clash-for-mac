import SwiftUI

/// 分组卡：卡头 32 + 三行节点 32 = 128pt，卡内不滚动（§3.4 / §4.6）。
/// 卡头右侧「还有 N 个 ›」是二级面板入口；行点击立即选中。
/// hover / 选中胶囊左右内缩 6pt、上下 2pt，避免与卡片描边或分隔线粘在一起。
@MainActor
struct GroupCardView: View {
    let group: DemoGroup
    let onOpen: () -> Void
    let onSelect: (UUID) -> Void
    /// 原型调试：强制某一行 hover（离屏快照用）
    var debugHoverRowIndex: Int?
    /// 原型调试：强制卡头 hover
    var debugHoverHeader = false

    @State private var isHeaderHovering = false
    @FocusState private var isHeaderFocused: Bool

    private var showsHeaderPill: Bool { isHeaderHovering || debugHoverHeader }

    var body: some View {
        VStack(spacing: 0) {
            header
            // 分隔线单独占一行，任何 hover / 选中底都盖不住它
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: Metrics.cardSeparatorHeight)

            ForEach(Array(group.visibleNodes.enumerated()), id: \.element.id) { index, node in
                NodeRowView(
                    node: node,
                    isSelected: group.isSelected(node),
                    isAvailable: node.latency != nil,
                    forcedHover: debugHoverRowIndex == index,
                    action: { onSelect(node.id) }
                )
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .fill(Theme.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: Metrics.hairline)
        }
    }

    private var header: some View {
        Button(action: onOpen) {
            HStack(spacing: 4) {
                Text(group.name)
                    .font(Typography.title)
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: 6)

                Text("还有 \(group.extraCount) 个")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: Metrics.groupCardHeaderHeight)
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
        .accessibilityLabel(Text("\(group.name)，还有 \(group.extraCount) 个节点"))
        .accessibilityHint("按下查看全部节点")
        .accessibilityAddTraits(.isButton)
    }
}
