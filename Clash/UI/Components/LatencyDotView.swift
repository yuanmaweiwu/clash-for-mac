import SwiftUI

/// 延迟点 8pt：< 100ms / 100–300ms / > 300ms 三档实心；
/// 未测速 = 1pt 空心环（还没数据，不是坏）；超时 = text/tertiary 实心（测过但不通）（§2.4 / §4.4）。
///
/// 缓存值（`isStale`）保留色阶色相，但整体降到 45% 透明度：色点仍能读出延迟等级，
/// 又明显比刚测出来的新鲜值淡。空心环只留给「未测速」，两者不能混。
@MainActor
struct LatencyDotView: View {
    let state: ProxyDelayState
    var isStale = false

    /// 陈旧值的整体透明度（深色模式下若实测不清，调这里）
    private static let staleOpacity = 0.45

    var body: some View {
        Group {
            switch state {
            case let .ok(latency):
                Circle()
                    .fill(color(for: latency))
                    .opacity(isStale ? Self.staleOpacity : 1)
                    .frame(width: 8, height: 8)
            case .unknown:
                Circle()
                    .strokeBorder(Theme.textTertiary, lineWidth: 1)
                    .frame(width: 8, height: 8)
            case .timeout:
                Circle()
                    .fill(Theme.textTertiary)
                    .opacity(isStale ? Self.staleOpacity : 1)
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
