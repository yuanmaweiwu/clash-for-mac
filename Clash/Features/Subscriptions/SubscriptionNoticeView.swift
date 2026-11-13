import SwiftUI

/// 订阅面板里的一次性提示（如删除当前订阅），3s 后自动消失。
@MainActor
struct SubscriptionNoticeView: View {
    let text: String

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.warning)

            Text(text)
                .font(Typography.caption)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                .fill(Theme.warning.opacity(0.14))
        }
    }
}
