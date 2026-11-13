import SwiftUI

/// 日志行：`HH:mm:ss`（灰，等宽）+ 级别色点 + 正文（可换行、可选中）。
///
/// 颜色只染级别点，不整行染色（`docs/02-UI-SPEC.md` §2.4：颜色是加速识别，不承担唯一信息）。
@MainActor
struct LogRowView: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(LogWindowMetrics.timeFormatter.string(from: line.date))
                .font(.system(size: 12).monospaced())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .frame(width: LogWindowMetrics.timeColumnWidth, alignment: .leading)

            Circle()
                .fill(LogLevelStyle.color(line.level))
                .frame(width: 6, height: 6)
                // 与首行文字视觉居中对齐（12pt 行的 x-height 中心）
                .padding(.top, 5)
                .accessibilityHidden(true)

            Text(line.payload)
                .font(.system(size: 12).monospaced())
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(line.level.title)，\(line.payload)"))
    }
}

/// 日志窗口的几何与格式化常量
@MainActor
enum LogWindowMetrics {
    /// 工具行（§3.2 状态条同高）
    static let toolbarHeight: CGFloat = 36
    /// 提示条（暂停 / 断连）
    static let noticeHeight: CGFloat = 20
    /// 距底部多少算「贴底」：在此范围内继续自动跟随
    static let tailSnapDistance: CGFloat = 40
    /// `HH:mm:ss` 列宽，保证正文左缘对齐（12pt 等宽 8 字符 ≈ 58pt，留 6pt 空隙）
    static let timeColumnWidth: CGFloat = 64

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// 级别 → 点色（`docs/02-UI-SPEC.md` §2.4）
@MainActor
enum LogLevelStyle {
    static func color(_ level: LogLine.Level) -> Color {
        switch level {
        case .error: Theme.error
        case .warning: Theme.warning
        case .info, .debug: Theme.textSecondary
        }
    }
}
