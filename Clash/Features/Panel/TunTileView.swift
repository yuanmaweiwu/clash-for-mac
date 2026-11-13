import SwiftUI

/// TUN 磁贴：v0.1 **不可用**（ADR-0007：无 root / 无 helper）。
///
/// 恒为灰态 + 副标题「需要管理员组件」，点击只解释原因，不做假开关。
/// v0.2 接入 helper 后再恢复「需要授权 → 等待授权 → 已开启 → 授权失败」五态（§4.2，
/// 枚举见 `Core/Models/TunState.swift`）。
@MainActor
struct TunTileView: View {
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
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityHint("按下查看不可用原因")
    }

    /// 不可用原因即副标题，不再有「已开启 / 已关闭」这类开关文案
    private var subtitle: String { "需要管理员组件" }

    /// 图标座灰：不用 success / warning 等状态色，避免读成「已开启」
    private var iconSeat: some View {
        ZStack {
            Circle()
                .fill(Theme.rowHover)
                .frame(width: 28, height: 28)

            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
