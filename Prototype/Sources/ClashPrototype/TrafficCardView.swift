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

/// 无数据：一条 hairline 虚线 + 居中「暂无流量」，不画波形（§4.5 空态）。
@MainActor
private struct NoTrafficChartView: View {
    var body: some View {
        ZStack {
            divider
            Text("暂无流量")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// 中段留出文字位置，避免虚线穿字
    private var divider: some View {
        let color = Theme.hairline
        return Canvas { @Sendable context, size in
            let midY = size.height / 2
            let labelGap: CGFloat = 84
            let leftEnd = max((size.width - labelGap) / 2, 0)
            let rightStart = min(leftEnd + labelGap, size.width)

            var path = Path()
            path.move(to: CGPoint(x: 0, y: midY))
            path.addLine(to: CGPoint(x: leftEnd, y: midY))
            path.move(to: CGPoint(x: rightStart, y: midY))
            path.addLine(to: CGPoint(x: size.width, y: midY))

            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
        }
    }
}
