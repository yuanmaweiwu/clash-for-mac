import Foundation

/// 60 点 / 1Hz 的假流量序列（0…1 归一化），以及演示用的初始速率。
enum DemoTraffic {
    static let initialDownRate = 8.4
    static let initialUpRate = 1.2

    static let downSeries: [Double] = makeSeries(
        amplitude: 0.40,
        phase: 0.4,
        peaks: [(15, 0.52), (43, 0.40), (53, 0.18)]
    )

    static let upSeries: [Double] = makeSeries(
        amplitude: 0.28,
        phase: 2.1,
        peaks: [(29, 0.55), (39, 0.16)]
    )

    static func format(rate: Double) -> String {
        String(format: "%.1f MB/s", rate)
    }

    /// VoiceOver 不读英文单位缩写（§6.1）
    static func spoken(rate: Double) -> String {
        String(format: "%.1f 兆字节每秒", rate)
    }

    /// 确定性波形：正弦底 + 若干高斯峰，看起来像真实采样。
    private static func makeSeries(
        amplitude: Double,
        phase: Double,
        peaks: [(center: Int, height: Double)]
    ) -> [Double] {
        (0..<60).map { index in
            let x = Double(index)
            var value = 0.30 + amplitude * (0.5 + 0.5 * sin(x / 6.0 + phase))
            value += 0.07 * sin(x / 1.9 + phase * 2)
            for peak in peaks {
                value += peak.height * exp(-pow((x - Double(peak.center)) / 4.0, 2))
            }
            return min(1, max(0.05, value))
        }
    }
}
