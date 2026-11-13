import SwiftUI

/// 订阅磁贴：纯导航，副标题 = 当前激活 profile；库 > 1 条时右上角计数徽标（§4.2）。
@MainActor
struct SubscriptionTileView: View {
    /// nil = 未导入配置
    let profileName: String?
    let badgeCount: Int
    let action: () -> Void

    var body: some View {
        TileShell(label: "订阅", value: profileName ?? "未添加", action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("订阅")
                        .font(Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 3) {
                        Text(profileName ?? "未添加")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if badgeCount > 1 {
                    countBadge
                }
            }
        }
    }

    private var countBadge: some View {
        Text("\(badgeCount)")
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 14)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.track)
            }
            .accessibilityLabel(Text("共 \(badgeCount) 条订阅"))
    }
}
