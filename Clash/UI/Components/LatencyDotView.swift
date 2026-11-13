import SwiftUI

/// 延迟点 8pt：< 100ms / 100–300ms / > 300ms 三档实心；
/// 未测速 = 1pt 空心环（还没数据，不是坏）；超时 = text/tertiary 实心（测过但不通）（§2.4 / §4.4）。
@MainActor
struct LatencyDotView: View {
    let state: ProxyDelayState

    var body: some View {
        Group {
            switch state {
            case let .ok(latency):
                Circle()
                    .fill(color(for: latency))
                    .frame(width: 8, height: 8)
            case .unknown:
                Circle()
                    .strokeBorder(Theme.textTertiary, lineWidth: 1)
                    .frame(width: 8, height: 8)
            case .timeout:
                Circle()
                    .fill(Theme.textTertiary)
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
