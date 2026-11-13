import SwiftUI

/// TUN 磁贴：已关闭 → 需要授权 →（等待授权）→ 已开启，全部本地模拟（§4.2）。
@MainActor
struct TunTileView: View {
    let state: TunState
    let action: () -> Void

    var body: some View {
        TileShell(label: "TUN", value: subtitle, action: action) {
            HStack(spacing: 8) {
                iconSeat
                VStack(alignment: .leading, spacing: 2) {
                    Text("TUN")
                        .font(Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(subtitleColor)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var subtitle: String {
        switch state {
        case .off: "已关闭"
        case .requiresAuth: "需要授权"
        case .waitingAuth: "等待授权"
        case .on: "已开启"
        case .authFailed: "授权失败"
        }
    }

    private var subtitleColor: Color {
        switch state {
        case .requiresAuth: Theme.warning
        case .authFailed: Theme.error
        case .on: Theme.textPrimary
        case .off, .waitingAuth: Theme.textSecondary
        }
    }

    private var seatColor: Color {
        switch state {
        case .on: Theme.success.opacity(0.16)
        case .requiresAuth: Theme.warning.opacity(0.16)
        case .authFailed: Theme.error.opacity(0.14)
        case .off, .waitingAuth: Theme.rowHover
        }
    }

    private var iconColor: Color {
        switch state {
        case .on: Theme.success
        case .requiresAuth: Theme.warning
        case .authFailed: Theme.error
        case .off, .waitingAuth: Theme.textSecondary
        }
    }

    private var iconSeat: some View {
        ZStack {
            Circle()
                .fill(seatColor)
                .frame(width: 28, height: 28)

            if state == .waitingAuth {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconColor)
            }
        }
    }
}
