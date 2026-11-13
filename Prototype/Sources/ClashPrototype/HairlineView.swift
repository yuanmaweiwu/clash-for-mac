import SwiftUI

/// 1px 分隔线：只在卡头 / 状态条 / 底栏出现。
@MainActor
struct HairlineView: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: Metrics.hairline)
            .accessibilityHidden(true)
    }
}
