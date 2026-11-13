import SwiftUI

/// 订阅空态卡：文案「还没有订阅」+ 导入入口（§4.8 / §7）。
@MainActor
struct EmptySubscriptionView: View {
    let onImportURL: () -> Void

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.textTertiary)

            Text("还没有订阅")
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)

            Button("导入订阅", action: onImportURL)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.emptyGroupCardHeight)
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
