import SwiftUI

/// 占位窗口的内容：说明「这一块还没做」，不假装可用。
@MainActor
struct PlaceholderPanelContentView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text("尚未实现")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 300, height: 150, alignment: .topLeading)
    }
}
