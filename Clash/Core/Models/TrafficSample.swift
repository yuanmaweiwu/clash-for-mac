import Foundation

/// `/traffic` WS 的一帧：内核上报的瞬时速率（字节 / 秒）。
///
/// 内核实际会多带 `upTotal` / `downTotal` 两个累计字段，这里只取速率，其余忽略。
struct TrafficSample: Decodable, Sendable, Equatable {
    let up: Double
    let down: Double
}

/// 速率文案（§4.5）：`B/s → KB/s → MB/s`，保留 1 位小数。
enum TrafficFormat {
    private static let kilobyte = 1024.0
    private static let megabyte = 1024.0 * 1024.0

    static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        if value < kilobyte { return String(format: "%.1f B/s", value) }
        if value < megabyte { return String(format: "%.1f KB/s", value / kilobyte) }
        return String(format: "%.1f MB/s", value / megabyte)
    }

    /// VoiceOver 不读英文单位缩写（§6.1）
    static func spoken(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        if value < kilobyte { return String(format: "%.1f 字节每秒", value) }
        if value < megabyte { return String(format: "%.1f 千字节每秒", value / kilobyte) }
        return String(format: "%.1f 兆字节每秒", value / megabyte)
    }
}
