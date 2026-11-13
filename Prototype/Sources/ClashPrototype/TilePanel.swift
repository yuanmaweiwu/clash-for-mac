import SwiftUI

/// 磁贴的纯视觉外壳（不可点版本，给内嵌分段控件的「代理模式」磁贴用）。
@MainActor
struct TilePanel<Content: View>: View {
    private let border: Color?
    private let isHoverable: Bool
    private let content: Content

    @State private var isHovering = false

    init(border: Color? = nil, isHoverable: Bool = false, @ViewBuilder content: () -> Content) {
        self.border = border
        self.isHoverable = isHoverable
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, Metrics.cardPadding)
            .frame(width: Metrics.tileWidth, height: Metrics.tileHeight, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .fill(isHoverable && isHovering ? Theme.cardHover : Theme.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .strokeBorder(border ?? Theme.hairline, lineWidth: Metrics.hairline)
            }
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
            .onHover { hovering in
                guard isHoverable else { return }
                isHovering = hovering
            }
            .animation(.easeInOut(duration: 0.14), value: isHovering)
    }
}
