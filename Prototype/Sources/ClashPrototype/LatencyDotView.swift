import SwiftUI

/// 延迟点 8pt：< 100ms / 100–300ms / > 300ms 三档实心，超时用 1pt 空心环（§2.4 / §4.4）。
@MainActor
struct LatencyDotView: View {
    let latency: Int?

    var body: some View {
        Group {
            if let latency {
                Circle()
                    .fill(color(for: latency))
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .strokeBorder(Theme.textTertiary, lineWidth: 1)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }

    private func color(for latency: Int) -> Color {
        switch latency {
        case ..<100: Theme.success
        case ..<300: Theme.latencyOk
        default: Theme.latencySlow
        }
    }
}
