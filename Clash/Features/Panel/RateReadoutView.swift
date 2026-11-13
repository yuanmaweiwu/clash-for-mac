import SwiftUI

/// 单个速率：箭头用数据色做加速识别，数字用 `font/number-lg` 等宽数字。
@MainActor
struct RateReadoutView: View {
    let arrow: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(Typography.numberLarge)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityHidden(true)
    }
}
