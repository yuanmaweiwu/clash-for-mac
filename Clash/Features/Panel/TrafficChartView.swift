import SwiftUI

/// 296×40 绘制区：60 点双色面积，下行在上、上行在下，0.18 填充 + 1.5pt 顶线，无坐标轴（§4.5）。
///
/// 入参是原始采样（字节 / 秒），Y 轴按窗口峰值自适应，最小满刻度 1 KB/s。
///
/// 用 `Shape` 描路径，不用 `Canvas`：`Canvas` 走 Metal，隐藏窗口里每秒一次采样也会重画，
/// 实测会把 GPU 表面一直留在脏状态（面板收起时 footprint 39MB → 95MB）。`Shape` 是往
/// 图层位图上描路径，没有额外表面，视觉上完全一致。
@MainActor
struct TrafficChartView: View {
    let downSeries: [Double]
    let upSeries: [Double]

    /// 顶线：1.5pt 圆头圆角（§4.5）
    private static let lineStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)

    var body: some View {
        ZStack {
            // 先两块面积，再两条顶线：线永远压在填充上，交叠处不发灰
            TrafficSeriesShape(values: downSeries, upward: true, isArea: true)
                .fill(Theme.trafficDown.opacity(0.18))
            TrafficSeriesShape(values: upSeries, upward: false, isArea: true)
                .fill(Theme.trafficUp.opacity(0.18))
            TrafficSeriesShape(values: downSeries, upward: true, isArea: false)
                .stroke(Theme.trafficDown, style: Self.lineStyle)
            TrafficSeriesShape(values: upSeries, upward: false, isArea: false)
                .stroke(Theme.trafficUp, style: Self.lineStyle)
        }
    }
}

/// Y 轴满刻度的下限：1 KB/s（§4.5「最小刻度 1 KB/s」）
private let minimumPeakBytesPerSecond = 1024.0

/// 60 点折线；`isArea` 时把折线两端接回中线闭合成面积。
///
/// 纯几何：不碰任何状态，只按 `rect` 把字节 / 秒换算成 y。
private struct TrafficSeriesShape: Shape {
    var values: [Double]
    /// 下行向上、上行向下
    var upward: Bool
    /// 面积填充（true）还是顶线（false）
    var isArea: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, rect.width > 0, rect.height > 1 else { return path }

        // 最小满刻度 1 KB/s：极低流量时不把噪点放大成满屏波形（§4.5）
        let peak = max(values.max() ?? 0, minimumPeakBytesPerSecond)
        let midY = rect.midY
        let amplitude = max(rect.height / 2 - 1, 1)
        let stepX = rect.width / CGFloat(values.count - 1)

        for (index, value) in values.enumerated() {
            let x = rect.minX + CGFloat(index) * stepX
            let ratio = CGFloat(value / peak)
            let y = upward ? midY - ratio * amplitude : midY + ratio * amplitude
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        if isArea {
            path.addLine(to: CGPoint(x: rect.maxX, y: midY))
            path.addLine(to: CGPoint(x: rect.minX, y: midY))
            path.closeSubpath()
        }
        return path
    }
}
