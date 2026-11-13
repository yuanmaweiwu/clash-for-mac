import SwiftUI

/// 空态占位卡 120pt：`tray` + 「还没有配置」+ 导入订阅 / 选择 YAML（§7）。
@MainActor
struct EmptyGroupView: View {
    /// 空态主文案：无配置「还没有配置」/ 有配置但无策略组「当前配置没有策略组」
    var title = "还没有配置"

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.textTertiary)

            Text(title)
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: Metrics.tileGap) {
                Text("导入订阅")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textOnAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                            .fill(Theme.accent)
                    }

                Text("选择 YAML")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .background {
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .fill(Theme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: Metrics.cardStroke)
                }
                .compositingGroup()
        }
        .accessibilityElement(children: .combine)
    }
}
