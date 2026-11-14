import SwiftUI

/// 「网络检测」区块（§3.2）：标题 20 + 间距 12 + 一排 4 个 73×56 磁贴 = 88pt。
///
/// 四个目标固定（Google / GitHub / Apple / YouTube），点任意一个都是**四个一起重测**：
/// 「本机网络通不通」是一个整体判断，逐个点只会让结论更慢出来。
@MainActor
struct NetworkProbeSectionView: View {
    let model: PanelPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("网络检测")
                .font(Typography.section)
                .foregroundStyle(Theme.textSecondary)
                .frame(height: Metrics.probeTitleHeight, alignment: .leading)

            HStack(spacing: Metrics.probeTileGap) {
                ForEach(model.networkProbeTargets) { target in
                    NetworkProbeTileView(
                        target: target,
                        state: model.networkProbeState(for: target)
                    ) {
                        model.testNetworkProbes()
                    }
                }
            }
            .padding(.top, Space.l)
        }
        .frame(height: Metrics.probeSectionHeight, alignment: .top)
    }
}

/// 单个检测磁贴 73×56：目标名 11pt + 延迟 / 状态（等宽数字）。
///
/// 四态与延迟色阶对齐 §2.4；「超时」用 `text/tertiary` 表示「测过但不通」，
/// 与「未测」的 `—` 区分开（前者是结论，后者是还没结论）。
private struct NetworkProbeTileView: View {
    let target: NetworkProbeService.Target
    let state: NetworkProbeService.State
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.hair) {
                Text(target.name)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)

                status
                    .frame(height: 14)
            }
            .frame(width: Metrics.probeTileWidth, height: Metrics.probeTileHeight)
            .background {
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: Metrics.cardStroke)
                    }
                    .compositingGroup()
            }
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .focused($isFocused)
        .focusEffectDisabled()
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Metrics.radiusCard + 2, style: .continuous)
                    .strokeBorder(Theme.focus, lineWidth: 2)
                    .padding(-2)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(target.name) 网络检测"))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint(Text("按下重测全部目标"))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .idle:
            Text("—")
                .font(Typography.captionNumber)
                .foregroundStyle(Theme.textTertiary)
        case .testing:
            ProgressView()
                .controlSize(.mini)
        case let .reachable(milliseconds):
            Text("\(milliseconds) ms")
                .font(Typography.captionNumber)
                .foregroundStyle(color(for: milliseconds))
        case .timeout:
            Text("超时")
                .font(Typography.captionNumber)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    @Environment(\.isPressed) private var isPressed

    private var fill: Color {
        if isPressed { return Theme.cardPressed }
        return isHovering ? Theme.cardHover : Theme.card
    }

    /// 延迟色阶（§2.4）：< 100 / 100–300 / > 300
    private func color(for latency: Int) -> Color {
        switch latency {
        case ..<100: Theme.success
        case ..<300: Theme.latencyOk
        default: Theme.latencySlow
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .idle: "未测速"
        case .testing: "测速中"
        case let .reachable(milliseconds): "延迟 \(milliseconds) 毫秒"
        case .timeout: "超时"
        }
    }
}
