import SwiftUI

/// 连接磁贴：28pt 圆形图标座 + 标题 / 副标题；点击在 未运行 → 启动中 → 代理中 ↔ 已就绪 之间走（§4.2）。
@MainActor
struct ConnectionTileView: View {
    let status: DemoStatus
    let action: () -> Void

    var body: some View {
        TileShell(border: borderColor, label: "连接", value: subtitle, action: action) {
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
        .accessibilityHint(status.isConnected ? "按下关闭代理" : "按下开启代理")
    }

    private var isOn: Bool { status.isConnected }

    private var subtitle: String {
        switch status {
        case .proxying, .direct: "已开启"
        case .starting: "正在启动"
        case .failed: "启动失败"
        case .idle, .ready: "已关闭"
        }
    }

    private var subtitleColor: Color {
        switch status {
        case .proxying, .direct: Theme.textPrimary
        case .failed: Theme.error
        case .idle, .ready, .starting: Theme.textSecondary
        }
    }

    private var borderColor: Color? {
        switch status {
        case .proxying, .direct: Theme.accentStroke
        case .failed: Theme.errorStroke
        case .idle, .ready, .starting: nil
        }
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
                    .foregroundStyle(isOn ? Theme.textOnAccent : Theme.textSecondary)
            }
        }
    }

    private var seatColor: Color {
        switch status {
        case .proxying, .direct: Theme.accent
        case .failed: Theme.error.opacity(0.14)
        case .idle, .ready, .starting: Theme.rowHover
        }
    }
}
