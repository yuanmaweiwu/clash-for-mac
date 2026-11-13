import SwiftUI

/// 订阅管理页的「读取中 / 读取失败」占位（§7：任何加载与失败都必须有可见反馈）。
///
/// 之前订阅页只认「空列表」，读盘慢或索引读不出来时就是一块白板；
/// 现在两种中间态各自有明确文案，失败态另给「重试」。
@MainActor
struct SubscriptionStateView: View {
    enum Kind: Equatable {
        case loading
        case failed(String)
    }

    let kind: Kind
    /// 仅失败态使用；读取中不需要
    var onRetry: () -> Void = {}

    var body: some View {
        VStack(spacing: Metrics.cardPadding) {
            switch kind {
            case .loading:
                ProgressView()
                    .controlSize(.small)

                Text("正在读取订阅…")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel(Text("正在读取订阅"))

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)

                Text("读取订阅失败")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textPrimary)

                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)

                Button("重试", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityHint(Text("重新读取订阅库"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
