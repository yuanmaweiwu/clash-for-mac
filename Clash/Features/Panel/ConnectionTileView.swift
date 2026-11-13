// TODO(v0.2): 恢复为系统代理总开关，届时磁贴语义改回「已开启/已关闭」
import SwiftUI

/// 连接磁贴：28pt 圆形图标座 + 标题 / 副标题。
///
/// v0.1 它其实是**内核启停**（ADR-0007：没有系统代理），
/// 所以副标题只说内核状态（已停止 / 启动中… / 内核已运行 / 启动失败），
/// 不用「已开启 / 已关闭」这种代理语义，也不给「开态」的强调色。
@MainActor
struct ConnectionTileView: View {
    let status: DemoStatus
    let action: () -> Void

    var body: some View {
        TileShell(label: "连接", value: subtitle, action: action) {
            HStack(spacing: 8) {
                iconSeat
                VStack(alignment: .leading, spacing: 2) {
                    Text("连接")
                        .font(Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(subtitleColor)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityHint(isKernelRunning ? "按下停止内核" : "按下启动内核")
    }

    private var isKernelRunning: Bool {
        switch status {
        case .ready, .proxying, .direct: true
        case .idle, .starting, .failed: false
        }
    }

    private var subtitle: String {
        switch status {
        case .idle: "已停止"
        case .starting: "启动中…"
        case .ready, .proxying, .direct: "内核已运行"
        case .failed: "启动失败"
        }
    }

    private var subtitleColor: Color {
        switch status {
        case .failed: Theme.error
        case .idle, .starting, .ready, .proxying, .direct: Theme.textSecondary
        }
    }

    private var borderColor: Color? {
        status == .failed ? Theme.errorStroke : nil
    }

    @ViewBuilder
    private var iconSeat: some View {
        ZStack {
            Circle()
                .fill(seatColor)
                .frame(width: 28, height: 28)

            switch status {
            case .starting:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.error)
            default:
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isKernelRunning ? Theme.textPrimary : Theme.textSecondary)
            }
        }
    }

    private var seatColor: Color {
        status == .failed ? Theme.error.opacity(0.14) : Theme.rowHover
    }
}
