import SwiftUI

/// 错误 banner 36pt：`surface/opaque` + `stroke/error`，整条可点（§7）。
/// 出现在状态条正下方，占固定高度，从分组区扣，不把面板撑高。
@MainActor
struct ErrorBannerView: View {
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.error)

                Text("内核启动失败，点此查看日志")
                    .font(Typography.status)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .frame(height: Metrics.bannerHeight)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .fill(Theme.opaque)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .strokeBorder(Theme.errorStroke, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .focused($isFocused)
        .focusEffectDisabled()
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Metrics.radiusCard + 2, style: .continuous)
                    .strokeBorder(Theme.focus, lineWidth: 2)
                    .padding(-2)
            }
        }
        .accessibilityLabel(Text("内核启动失败，点此查看日志"))
        .accessibilityAddTraits(.isButton)
    }
}
