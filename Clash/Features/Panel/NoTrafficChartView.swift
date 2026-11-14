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

    private var divider: some View {
        DashedDividerShape()
            .stroke(
                Theme.hairline,
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
    }
}

/// 中段留出文字位置，避免虚线穿字。
///
/// 与曲线一样用 `Shape`：静态虚线不需要为它保留一张绘制表面。
private struct DashedDividerShape: Shape {
    /// 文字占位宽度（「暂无流量」四个字 + 两侧各留一点）
    var labelGap: CGFloat = 84

    func path(in rect: CGRect) -> Path {
        let midY = rect.midY
        let leftEnd = max((rect.width - labelGap) / 2, 0)
        let rightStart = min(leftEnd + labelGap, rect.width)

        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY))
        path.addLine(to: CGPoint(x: leftEnd, y: midY))
        path.move(to: CGPoint(x: rightStart, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))
        return path
    }
}
