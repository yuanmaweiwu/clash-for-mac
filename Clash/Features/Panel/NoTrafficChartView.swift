import SwiftUI

/// 无数据：一条 hairline 虚线 + 居中「暂无流量」，不画波形（§4.5 空态）。
@MainActor
struct NoTrafficChartView: View {
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
