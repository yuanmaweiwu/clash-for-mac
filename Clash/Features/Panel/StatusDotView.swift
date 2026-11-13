import SwiftUI

/// 状态点 7pt：空心 / 实心 / 6pt ProgressView（§3.3）。
@MainActor
struct StatusDotView: View {
    let status: DemoStatus

    var body: some View {
        ZStack {
            switch status {
            case .starting:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            case .idle:
                Circle()
                    .strokeBorder(Theme.textTertiary, lineWidth: 1)
                    .frame(width: 7, height: 7)
            case .proxying:
                Circle()
                    .fill(Theme.success)
                    .frame(width: 7, height: 7)
            case .ready, .direct:
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: 7, height: 7)
            case .failed:
                Circle()
                    .fill(Theme.error)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}
