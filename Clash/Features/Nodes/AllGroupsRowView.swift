import SwiftUI

/// 全部策略组的一行 48pt（两行：组名 + 节点数）：单选，选中行用与节点行同款的
/// `surface/row-selected` 胶囊 + 加粗名称（§4.7）。
///
/// 点整行 = 设为当前展示组（替换旧的，不叠加）；首屏永远只展示这一张卡。
/// 行尾只放状态文字：「全局」/「未生效」，不再有星标与「已固定」。
/// 整行是按钮（键盘可 Tab、可 Space 触发、有焦点环）。
@MainActor
struct AllGroupsRowView: View {
    let group: ProxyGroupModel
    /// 是否是当前展示组
    let isSelected: Bool
    /// 该组没有被任何规则引用（§4.7）：行尾提示，仅作说明
    let showsInactiveLabel: Bool
    let onSelect: () -> Void

    @State private var isHovering = false
    @FocusState private var isRowFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            rowBody
        }
        .buttonStyle(PressableButtonStyle())
        .focused($isRowFocused)
        .focusEffectDisabled()
        .accessibilityLabel(Text(group.name))
        .accessibilityValue(Text(rowValue))
        .accessibilityHint(Text("按下切换展示的策略组"))
        .overlay {
            if isRowFocused {
                RoundedRectangle(cornerRadius: Metrics.radiusRow + 2, style: .continuous)
                    .strokeBorder(Theme.focus, lineWidth: 2)
                    .padding(-2)
            }
        }
        .frame(height: Metrics.listRowHeight)
        .background { rowBackground }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovering)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }

    /// 名称 + 节点数在左，状态标签在行尾竖向居中
    private var rowBody: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(group.name)
                    .font(isSelected ? Typography.title : Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(group.nodes.count) 个节点")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: Space.s)

            if let statusText {
                Text(statusText)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// `GLOBAL` 标「全局」；其它组只标「未生效」（生效组行尾留空）
    private var statusText: String? {
        if group.isGlobal { return "全局" }
        return showsInactiveLabel ? "未生效" : nil
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected || isHovering {
            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                .fill(isSelected ? Theme.rowSelected : Theme.rowHover)
                .padding(.horizontal, Metrics.pillInsetH)
                .padding(.vertical, Metrics.listPillInsetV)
        }
    }

    /// 读屏先报是否当前展示，再报节点数与是否生效
    private var rowValue: String {
        var parts = [isSelected ? "当前展示" : "未展示"]
        if showsInactiveLabel { parts.append("未生效") }
        parts.append("\(group.nodes.count) 个节点")
        return parts.joined(separator: "，")
    }
}
