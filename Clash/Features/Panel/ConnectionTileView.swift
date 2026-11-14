import SwiftUI

/// 系统代理磁贴：**系统代理总开关**（`docs/02-UI-SPEC.md` §4.2）。
///
/// 未启用 → 点击 = 只还原系统代理（内核继续运行）；已启用 → 点击 = 内核没跑先启动 + 接管系统代理。
/// 四个视觉态：未启用 / 已启用（accent 描边）/ 过渡中（转圈）/ 失败（error 描边 + 感叹号）。
///
/// 图标用 `globe.americas.fill`：和 TUN 的盾牌一眼能分开，而且实心字形在 accent 圆底反白后
/// 仍然清楚（`network` 这种线框字形铺在实心圆上会糊成一团）。
///
/// 标题写「系统代理」而不是「连接」：它和 TUN 磁贴是**替代关系**（任选其一），
/// 叫「连接」会被读成「连上内核的开关」，看起来像两个都得开。
@MainActor
struct ConnectionTileView: View {
    let state: ConnectionState
    let action: () -> Void

    var body: some View {
        TileShell(border: borderColor, label: "系统代理", value: state.subtitle, action: action) {
            HStack(spacing: Space.m) {
                iconSeat
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text("系统代理")
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
                .frame(width: Metrics.hitTarget, height: Metrics.hitTarget)

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
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textOnAccent)
            case .off:
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 13, weight: .medium))
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
