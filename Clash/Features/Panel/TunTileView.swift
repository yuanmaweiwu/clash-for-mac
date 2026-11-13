import SwiftUI

/// TUN 磁贴（`docs/02-UI-SPEC.md` §4.2）。
///
/// 五态 + 过渡：已关闭 / 需要授权（warning）/ 等待授权（转圈）/ 已开启（accent 描边）/
/// 授权失败、开启失败（error 描边）。与连接磁贴同结构：28pt 圆形图标座 + 标题 + 副标题。
///
/// 文案与无障碍提示都来自 `TunState`，视图只负责配色，避免两处写文案走样。
@MainActor
struct TunTileView: View {
    let state: TunState
    let action: () -> Void

    var body: some View {
        TileShell(border: borderColor, label: "TUN", value: state.subtitle, action: action) {
            HStack(spacing: 8) {
                iconSeat
                VStack(alignment: .leading, spacing: 2) {
                    Text("TUN")
                        .font(Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text(state.subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(subtitleColor)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityHint(state.accessibilityHint)
        .accessibilityAddTraits(state == .on ? .isSelected : [])
    }

    private var subtitleColor: Color {
        switch state {
        case .on: Theme.textPrimary
        case .requiresAuth: Theme.warning
        case .authFailed, .startFailed: Theme.error
        case .off, .waitingAuth, .starting, .stopping: Theme.textSecondary
        }
    }

    private var borderColor: Color? {
        switch state {
        case .on: Theme.accentStroke
        case .authFailed, .startFailed: Theme.errorStroke
        case .off, .requiresAuth, .waitingAuth, .starting, .stopping: nil
        }
    }

    @ViewBuilder
    private var iconSeat: some View {
        ZStack {
            Circle()
                .fill(seatColor)
                .frame(width: 28, height: 28)

            if state.isProgressing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconColor)
            }
        }
    }

    private var iconName: String {
        switch state {
        case .authFailed, .startFailed: "exclamationmark"
        case .on: "shield.lefthalf.filled"
        case .requiresAuth: "lock.fill"
        case .off, .waitingAuth, .starting, .stopping: "shield.lefthalf.filled"
        }
    }

    private var iconColor: Color {
        switch state {
        case .on: Theme.textOnAccent
        case .requiresAuth: Theme.warning
        case .authFailed, .startFailed: Theme.error
        case .off, .waitingAuth, .starting, .stopping: Theme.textSecondary
        }
    }

    private var seatColor: Color {
        switch state {
        case .on: Theme.accent
        case .authFailed, .startFailed: Theme.error.opacity(0.14)
        case .requiresAuth: Theme.warning.opacity(0.14)
        case .off, .waitingAuth, .starting, .stopping: Theme.rowHover
        }
    }
}
