import SwiftUI

/// 订阅空态卡：文案「还没有订阅」+ 导入入口（§4.8 / §7）。
@MainActor
struct EmptySubscriptionView: View {
    let onImportURL: () -> Void
    let onImportYAML: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.textTertiary)

            Text("还没有订阅")
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: Metrics.tileGap) {
                Button("导入订阅", action: onImportURL)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .font(.system(size: 11, weight: .medium))

                Button("选择 YAML", action: onImportYAML)
                    .buttonStyle(.plain)
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
    }
}
