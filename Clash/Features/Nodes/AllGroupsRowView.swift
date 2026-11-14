import SwiftUI

/// 全部策略组的一行 48pt（两行：组名 + 节点数）：hover / 当前组用同一套胶囊。
///
/// 这一页是**策略组管理（pin）**：点整行 = 切换是否固定到首屏；进去选节点走首屏卡片头的「还有 N 个 ›」。
/// 唯一例外是 `GLOBAL`：全局模式下它是选节点的唯一入口，点行仍进全局节点列表，行尾标「全局」。
/// 固定状态不用图标：已固定 → 名称加粗 + 行尾「已固定」，未固定 → 常规字重、行尾不加字。
/// 整行是按钮（键盘可 Tab、可 Space 触发、有焦点环）。
@MainActor
struct AllGroupsRowView: View {
    let group: ProxyGroupModel
    let isActive: Bool
    /// 该组没有被任何规则引用（§4.7）：行尾提示，仅作说明，不影响 pin
    let showsInactiveLabel: Bool
    let onTogglePin: () -> Void
    /// `GLOBAL` 专用：打开全局节点列表（唯一还保留的节点入口）
    let onOpen: () -> Void

    @State private var isHovering = false
    @FocusState private var isRowFocused: Bool

    var body: some View {
        Button(action: handleTap) {
            rowBody
        }
        .buttonStyle(PressableButtonStyle())
        .focused($isRowFocused)
        .focusEffectDisabled()
        .accessibilityLabel(Text(group.name))
        .accessibilityValue(Text(rowValue))
        .accessibilityHint(Text(rowHint))
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
        .animation(.easeInOut(duration: 0.18), value: isActive)
        .animation(.easeInOut(duration: 0.18), value: group.isPinned)
    }

    /// 名称 + 节点数在左，状态标签在行尾竖向居中；右侧不再给图标留热区
    private var rowBody: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(group.name)
                    .font(group.isPinned ? Typography.title : Typography.body)
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
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// 行点击：`GLOBAL` 进全局节点列表（全局模式的唯一入口），其余组切换固定
    private func handleTap() {
        if group.isGlobal {
            onOpen()
        } else if group.canPin {
            onTogglePin()
        }
    }

    /// 「已固定 · 未生效」/ 只有其中一项 / 都没有（未固定的生效组）；`GLOBAL` 固定显示「全局」
    private var statusText: String? {
        if group.isGlobal { return "全局" }
        var parts: [String] = []
        if group.isPinned { parts.append("已固定") }
        if showsInactiveLabel { parts.append("未生效") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    /// 读屏先报固定状态与生效状态，再报节点数；`GLOBAL` 只报「全局组」
    private var rowValue: String {
        if group.isGlobal { return "全局组，\(group.nodes.count) 个节点" }
        var parts = [group.isPinned ? "已固定到首屏" : "未固定"]
        if showsInactiveLabel { parts.append("未生效") }
        parts.append("\(group.nodes.count) 个节点")
        return parts.joined(separator: "，")
    }

    private var rowHint: String {
        if group.isGlobal { return "按下查看全局节点" }
        guard group.canPin else { return "主组固定显示" }
        return "按下切换是否固定到首屏"
    }
}
