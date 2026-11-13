import SwiftUI

/// 空态占位卡 120pt：`tray` + 「还没有配置」+ 导入订阅 / 选择 YAML（§7）。
@MainActor
struct EmptyGroupView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.textTertiary)

            Text("还没有配置")
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
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: Metrics.hairline)
        }
        .accessibilityElement(children: .combine)
    }
}
