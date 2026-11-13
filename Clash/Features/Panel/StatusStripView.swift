import SwiftUI

/// 状态条 36pt：状态点 + 短语（左），↑ / ↓ 速率（右），底部 1px hairline（§3.2 / §3.3）。
@MainActor
struct StatusStripView: View {
    let status: DemoStatus
    let downText: String
    let upText: String

    var body: some View {
        HStack(spacing: 6) {
            StatusDotView(status: status)

            Text(status.title)
                .font(Typography.status)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            if status.hasLiveRates {
                HStack(spacing: 10) {
                    RateReadoutView(arrow: "arrow.up", value: upText, tint: Theme.trafficUp)
                    RateReadoutView(arrow: "arrow.down", value: downText, tint: Theme.trafficDown)
                }
            } else {
                Text("—")
                    .font(Typography.numberLarge)
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: Metrics.statusBarHeight)
        .overlay(alignment: .bottom) { HairlineView() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("状态")
        .accessibilityValue(status.hasLiveRates ? "\(status.title)，上传 \(upText)，下载 \(downText)" : status.title)
    }
}
