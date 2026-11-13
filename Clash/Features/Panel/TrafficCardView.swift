import SwiftUI

/// 曲线卡 80pt：标题行 16 + 间距 4 + 绘制区 40，内边距 10（§3.2 / §4.5）。
@MainActor
struct TrafficCardView: View {
    /// 有采样：画 60 点曲线；无采样：虚线 + 「暂无流量」空态
    let hasCurve: Bool
    /// WS 在线：数值实时；断连时曲线 30% 透明、数值回 `—`（§4.5 断连态）
    let isLive: Bool
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
                if hasCurve {
                    TrafficChartView(downSeries: downSeries, upSeries: upSeries)
                        // 断连：保留波形但降透明度，明确「数据暂停」
                        .opacity(isLive ? 1 : 0.3)
                } else {
                    NoTrafficChartView()
                }
            }
            .frame(height: Metrics.chartHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("实时流量")
            .accessibilityValue(accessibilityValue)
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
            Text(isLive ? TrafficFormat.rate(value) : "—")
                .font(Typography.number)
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
        .accessibilityHidden(true)
    }

    /// 无采样 → 空态；断连 → 只报「数据暂停」不报旧数字；在线 → 报实时上下行
    private var accessibilityValue: String {
        guard hasCurve else { return "暂无流量" }
        guard isLive else { return "数据暂停" }
        return "下载 \(TrafficFormat.spoken(downRate))，上传 \(TrafficFormat.spoken(upRate))"
    }
}
