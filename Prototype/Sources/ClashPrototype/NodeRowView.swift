import SwiftUI

/// 节点行 32pt：8pt 延迟点 + 名称 + 延迟（§4.4）。
/// hover / 选中胶囊左右内缩 6pt、上下 4pt（高 24），文字距胶囊边 4pt。
/// 选中态只靠底色 + 加粗表达，行尾不放 ✓；延迟数字右对齐到卡内边距 10pt。
@MainActor
struct NodeRowView: View {
    let node: DemoNode
    let isSelected: Bool
    let isAvailable: Bool
    /// 原型调试：强制按 hover 渲染（离屏快照用）
    var forcedHover = false
    /// 二级列表用 44，卡片内保持 32
    var rowHeight: CGFloat?
    /// 二级列表胶囊上下内缩 4；卡片内用 token 的 2
    var pillInsetV: CGFloat?
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var showsPill: Bool { isSelected || isHovering || forcedHover }

    var body: some View {
        Button(action: action) {
            rowContent
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isAvailable)
        .focused($isFocused)
        .focusEffectDisabled()
        .overlay {
            if isFocused && isAvailable {
                // 焦点环不跟胶囊收：2pt 外扩（§2.2 / §6.2）
                RoundedRectangle(cornerRadius: Metrics.radiusRow + 2, style: .continuous)
                    .strokeBorder(Theme.focus, lineWidth: 2)
                    .padding(-2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(node.name))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            LatencyDotView(latency: node.latency)

            Text(node.name)
                .font(isSelected ? Typography.title : Typography.body)
                .foregroundStyle(isAvailable ? Theme.textPrimary : Theme.textPrimary.opacity(0.4))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Text(node.latencyText)
                .font(Typography.number)
                .foregroundStyle(isAvailable ? Theme.textSecondary : Theme.textTertiary)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(maxWidth: .infinity)
        .frame(height: rowHeight ?? Metrics.rowHeight)
        .background {
            if showsPill {
                RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                    .fill(isSelected ? Theme.rowSelected : Theme.rowHover)
                    .padding(.horizontal, Metrics.pillInsetH)
                    .padding(.vertical, pillInsetV ?? Metrics.pillInsetV)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard isAvailable else { return }
            isHovering = hovering
        }
        .animation(.easeInOut(duration: 0.18), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }

    private var accessibilityValue: String {
        guard let latency = node.latency else { return "不可用" }
        return isSelected ? "延迟 \(latency) 毫秒，已选中" : "延迟 \(latency) 毫秒"
    }
}
