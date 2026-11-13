import SwiftUI

/// 曲线卡 80pt：标题行 16 + 间距 4 + 绘制区 40，内边距 10（§3.2 / §4.5）。
@MainActor
struct TrafficCardView: View {
    let status: DemoStatus
    let downRate: Double
    let upRate: Double
    let downSeries: [Double]
    let upSeries: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("流量")
                    .font(Typography.section)
                    .foregroundStyle(Theme.textSecondary)

                legendDot(Theme.trafficDown, label: "下行")
                legendDot(Theme.trafficUp, label: "上行")

                Spacer(minLength: 4)

                rate(arrow: "arrow.down", value: downRate, tint: Theme.trafficDown)
                rate(arrow: "arrow.up", value: upRate, tint: Theme.trafficUp)
            }
            .frame(height: 16)

            Group {
                if status.hasLiveRates {
                    TrafficChartView(downSeries: downSeries, upSeries: upSeries)
                } else {
                    NoTrafficChartView()
                }
            }
            .frame(height: Metrics.chartHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("实时流量")
            .accessibilityValue(
                status.hasLiveRates
                    ? "下载 \(DemoTraffic.spoken(rate: downRate))，上传 \(DemoTraffic.spoken(rate: upRate))"
                    : "暂无流量"
            )
        }
        .padding(Metrics.cardPadding)
        .frame(height: Metrics.chartCardHeight, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .fill(Theme.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: Metrics.hairline)
        }
    }

    private func legendDot(_ color: Color, label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityHidden(true)
    }

    private func rate(arrow: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: arrow)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tint)
            Text(status.hasLiveRates ? DemoTraffic.format(rate: value) : "—")
                .font(Typography.number)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityHidden(true)
    }
}
