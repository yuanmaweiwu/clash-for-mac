import SwiftUI

/// 「网络检测」区块（§3.2）：标题 20（右侧刷新）+ 间距 12 + 一排 4 个 73×56 磁贴 = 88pt。
///
/// 四个目标固定（Google / GitHub / Apple / YouTube），点任意一个磁贴或标题行刷新按钮
/// 都是**四个一起重测**：「本机网络通不通」是一个整体判断，逐个点只会让结论更慢出来。
@MainActor
struct NetworkProbeSectionView: View {
    let model: PanelPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s) {
                Text("网络检测")
                    .font(Typography.section)
                    .foregroundStyle(Theme.textSecondary)

                Spacer(minLength: Space.s)

                refreshControl
            }
            // 标题行 20pt；刷新按钮 28pt 热区上下各溢出 4pt，落进 12pt 的磁贴间距里
            .frame(height: Metrics.probeTitleHeight)

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

    /// 测速中换成 12pt `ProgressView` 且不可点：与测速互斥，连点不会重启一轮
    @ViewBuilder
    private var refreshControl: some View {
        if model.isTestingNetworkProbes {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: Metrics.hitTarget, height: Metrics.hitTarget)
                .allowsHitTesting(false)
                .accessibilityLabel(Text("测速中"))
        } else {
            IconButtonView(
                systemName: "arrow.clockwise",
                label: "重测全部目标",
                iconSize: 16,
                restingTint: Theme.textTertiary
            ) {
                model.testNetworkProbes()
            }
            .accessibilityHint(Text("四个目标一起重测"))
        }
    }
}

/// 单个检测磁贴 73×56：品牌 logo（16）+ 目标名（11）+ 延迟 / 状态（10 等宽）。
///
/// 三行居中排布、互不挤压；模板单色渲染，深浅色都由文字色决定，不会发灰。
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
            VStack(spacing: Space.xs) {
                Image(target.iconAssetName)
                    .renderingMode(target.logoIsTemplate ? .template : .original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityHidden(true)

                // 名称与延迟是一组：彼此 2pt，和 logo 之间 4pt，三行不糊成一团
                VStack(spacing: Space.hair) {
                    Text(target.name)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)

                    status
                        .frame(height: 12)
                }
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
                .font(Typography.probeValue)
                .foregroundStyle(Theme.textTertiary)
        case .testing:
            ProgressView()
                .controlSize(.mini)
        case let .reachable(milliseconds):
            Text("\(milliseconds) ms")
                .font(Typography.probeValue)
                .foregroundStyle(color(for: milliseconds))
        case .timeout:
            Text("超时")
                .font(Typography.probeValue)
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

/// 品牌图标只做「表现层」映射：素材在 Assets，Core 里的 `Target` 不关心资源名。
private extension NetworkProbeService.Target {
    var iconAssetName: String {
        switch self {
        case .google: "ProbeGoogle"
        case .github: "ProbeGitHub"
        case .apple: "ProbeApple"
        case .youtube: "ProbeYouTube"
        }
    }

    /// 品牌本身是单色（Apple / GitHub）走模板，浅色黑、深色白自动反白；
    /// Google / YouTube 是官方多色，保留原色，不进模板（否则会变灰/单色）。
    var logoIsTemplate: Bool {
        switch self {
        case .apple, .github: true
        case .google, .youtube: false
        }
    }
}
