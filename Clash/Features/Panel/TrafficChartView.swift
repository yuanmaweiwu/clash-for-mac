import SwiftUI

/// 296×40 绘制区：60 点双色面积，下行在上、上行在下，0.18 填充 + 1.5pt 顶线，无坐标轴（§4.5）。
///
/// 入参是原始采样（字节 / 秒），Y 轴按窗口峰值自适应，最小满刻度 1 KB/s。
@MainActor
struct TrafficChartView: View {
    let downSeries: [Double]
    let upSeries: [Double]

    var body: some View {
        let downColor = Theme.trafficDown
        let upColor = Theme.trafficUp

        // SwiftUI 可能在线程外调用绘制闭包，这里保持 nonisolated
        Canvas { @Sendable context, size in
            drawSeries(downSeries, in: context, size: size, upward: true, color: downColor)
            drawSeries(upSeries, in: context, size: size, upward: false, color: upColor)
        }
    }
}

/// Y 轴满刻度的下限：1 KB/s（§4.5「最小刻度 1 KB/s」）
private let minimumPeakBytesPerSecond = 1024.0

/// 纯绘制函数：不碰任何状态，保住 Canvas 闭包的隔离约束。
private func drawSeries(
    _ values: [Double],
    in context: GraphicsContext,
    size: CGSize,
    upward: Bool,
    color: Color
) {
    guard values.count > 1, size.width > 0, size.height > 1 else { return }

    // 最小满刻度 1 KB/s：极低流量时不把噪点放大成满屏波形（§4.5）
    let peak = max(values.max() ?? 0, minimumPeakBytesPerSecond)
    let midY = size.height / 2
    let amplitude = max(midY - 1, 1)
    let stepX = size.width / CGFloat(values.count - 1)

    var line = Path()
    for (index, value) in values.enumerated() {
        let x = CGFloat(index) * stepX
        let ratio = CGFloat(value / peak)
        let y = upward ? midY - ratio * amplitude : midY + ratio * amplitude
        if index == 0 {
            line.move(to: CGPoint(x: x, y: y))
        } else {
            line.addLine(to: CGPoint(x: x, y: y))
        }
    }

    var area = line
    area.addLine(to: CGPoint(x: size.width, y: midY))
    area.addLine(to: CGPoint(x: 0, y: midY))
    area.closeSubpath()

    context.fill(area, with: .color(color.opacity(0.18)))
    context.stroke(
        line,
        with: .color(color),
        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
    )
}
