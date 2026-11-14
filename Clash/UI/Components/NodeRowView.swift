import SwiftUI

/// 节点行 32pt：8pt 延迟点 + 名称 + 延迟（§4.4）。
/// hover / 选中胶囊左右内缩 6pt、上下 4pt（高 24），文字距胶囊边 4pt。
/// 选中态只靠底色 + 加粗表达，行尾不放 ✓；延迟数字右对齐到卡内边距 10pt。
@MainActor
struct NodeRowView: View {
    let node: ProxyNodeModel
    let isSelected: Bool
    let isAvailable: Bool
    /// 测速中：延迟位换成 10pt ProgressView
    var isTesting = false
    /// 二级列表用 44，卡片内保持 32
    var rowHeight: CGFloat?
    /// 二级列表胶囊上下内缩 4；卡片内用 token 的 2
    var pillInsetV: CGFloat?
    let action: () -> Void

    @Environment(\.isPressed) private var isPressed
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var showsPill: Bool { isSelected || isHovering || isPressed }

    var body: some View {
        Button(action: action) {
            rowLabel
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

    /// 陈旧值 hover 提示「上次测速：N 分钟前」；新鲜值不加多余 tooltip
    @ViewBuilder
    private var rowLabel: some View {
        if let hint = node.staleHint {
            rowContent.help(hint)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: Space.s) {
            LatencyDotView(state: node.delayState, isStale: node.isStale)

            Text(node.name)
                .font(isSelected ? Typography.title : Typography.body)
                .foregroundStyle(isAvailable ? Theme.textPrimary : Theme.textPrimary.opacity(0.4))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Space.s)

            if isTesting {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.98)
                    .frame(width: 34, height: 16, alignment: .trailing)
                    .accessibilityHidden(true)
            } else {
                Text(node.latencyText)
                    .font(Typography.number)
                    .foregroundStyle(isAvailable ? Theme.textSecondary : Theme.textTertiary)
            }
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(maxWidth: .infinity)
        .frame(height: rowHeight ?? Metrics.rowHeight)
        .background {
            if showsPill {
                RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                    .fill(isSelected ? Theme.rowSelected : (isPressed ? Theme.cardPressed : Theme.rowHover))
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
        if isTesting { return "测速中" }

        let staleNote = node.isStale ? "（\(node.staleHint ?? "上次测速")）" : ""
        let selectedNote = isSelected ? "，已选中" : ""
        switch node.delayState {
        case let .ok(latency):
            return "延迟 \(latency) 毫秒\(staleNote)\(selectedNote)"
        case .timeout:
            return "超时\(staleNote)\(selectedNote)"
        case .unknown:
            return "未测速\(selectedNote)"
        }
    }
}
