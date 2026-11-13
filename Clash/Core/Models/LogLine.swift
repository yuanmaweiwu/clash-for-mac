import Foundation

/// `/logs` 推来的一条内核日志（`core-process` §5：`{"type":"info|warning|error","payload":"..."}`）。
///
/// 内核不给时间戳，`date` 是**收到时间**；`payload` 在进入缓冲前已由 `LogStore` 脱敏，
/// 展示与导出都直接用这一份，不存在「忘了打码」的旁路。
struct LogLine: Identifiable, Equatable, Sendable {

    /// 内核日志级别；线上出现未知值时按 `info` 处理，不丢行（`core-process` §5）
    enum Level: String, CaseIterable, Sendable {
        case debug
        case info
        case warning
        case error

        init(wire: String) {
            self = Level(rawValue: wire.lowercased()) ?? .info
        }

        /// 工具行 chip 文案
        var title: String { rawValue }

        /// 工具行可切换的三档：`debug` 不展示，因此也不请求（见 `LogStore.streamLevel`）
        static let chips: [Level] = [.info, .warning, .error]
    }

    let id: UUID
    let level: Level
    /// 已脱敏正文
    let payload: String
    /// 收到时间
    let date: Date

    init(id: UUID = UUID(), level: Level, payload: String, date: Date = .now) {
        self.id = id
        self.level = level
        self.payload = payload
        self.date = date
    }
}

extension LogLine {
    /// 线上帧
    struct Wire: Decodable, Sendable {
        let type: String
        let payload: String
    }

    /// 帧 → 行；字段缺失 / 类型不对都按不可解析处理（调用方跳过该帧）
    init?(wire data: Data) {
        guard let frame = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        self.init(level: Level(wire: frame.type), payload: frame.payload)
    }
}
