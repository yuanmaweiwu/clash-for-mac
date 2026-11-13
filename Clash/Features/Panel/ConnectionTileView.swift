import SwiftUI

/// 连接磁贴：**系统代理总开关**（`docs/02-UI-SPEC.md` §4.2）。
///
/// 关闭 → 点击 = 起内核 + 接管系统代理；开启 → 点击 = 还原系统代理并停内核。
/// 四个视觉态：关 / 开（accent 描边）/ 过渡中（转圈）/ 失败（error 描边 + 感叹号）。
@MainActor
struct ConnectionTileView: View {
    let state: ConnectionState
    let action: () -> Void

    var body: some View {
        TileShell(border: borderColor, label: "连接", value: state.subtitle, action: action) {
            HStack(spacing: 8) {
                iconSeat
                VStack(alignment: .leading, spacing: 2) {
                    Text("连接")
                        .font(Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text(state.subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(subtitleColor)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityHint(state.hint)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var isOn: Bool { state == .on }

    private var subtitleColor: Color {
        switch state {
        case .on: Theme.textPrimary
        case .failed(_): Theme.error
        case .off, .turningOn, .turningOff: Theme.textSecondary
        }
    }

    private var borderColor: Color? {
        switch state {
        case .on: Theme.accentStroke
        case .failed(_): Theme.errorStroke
        case .off, .turningOn, .turningOff: nil
        }
    }

    @ViewBuilder
    private var iconSeat: some View {
        ZStack {
            Circle()
                .fill(seatColor)
                .frame(width: 28, height: 28)

            switch state {
            case .turningOn, .turningOff:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            case .failed(_):
                Image(systemName: "exclamationmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.error)
            case .on:
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textOnAccent)
            case .off:
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var seatColor: Color {
        switch state {
        case .on: Theme.accent
        case .failed(_): Theme.error.opacity(0.14)
        case .off, .turningOn, .turningOff: Theme.rowHover
        }
    }
}
