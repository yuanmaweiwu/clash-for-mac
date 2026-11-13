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

/// 状态点 7pt：空心 / 实心 / 6pt ProgressView（§3.3）。
@MainActor
private struct StatusDotView: View {
    let status: DemoStatus

    var body: some View {
        ZStack {
            switch status {
            case .starting:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            case .idle:
                Circle()
                    .strokeBorder(Theme.textTertiary, lineWidth: 1)
                    .frame(width: 7, height: 7)
            case .proxying:
                Circle()
                    .fill(Theme.success)
                    .frame(width: 7, height: 7)
            case .ready, .direct:
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: 7, height: 7)
            case .failed:
                Circle()
                    .fill(Theme.error)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}

/// 单个速率：箭头用数据色做加速识别，数字用 `font/number-lg` 等宽数字。
@MainActor
private struct RateReadoutView: View {
    let arrow: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(Typography.numberLarge)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityHidden(true)
    }
}
