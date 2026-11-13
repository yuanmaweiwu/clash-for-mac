import SwiftUI

/// 磁贴的纯视觉外壳（不可点版本，给内嵌分段控件的「代理模式」磁贴用）。
///
/// 153×64 尺寸是几何锁定值：卡内左右 12pt、上下由内容决定。
/// 分层只靠 fill + 1pt 描边，不用阴影（§2.2）。
@MainActor
struct TilePanel<Content: View>: View {
    private let border: Color?
    private let isHoverable: Bool
    private let content: Content

    @Environment(\.isPressed) private var isPressed
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
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                            .strokeBorder(border ?? Theme.hairline, lineWidth: Metrics.cardStroke)
                    }
                    .compositingGroup()
            }
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
            .onHover { hovering in
                guard isHoverable else { return }
                isHovering = hovering
            }
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }

    private var fill: Color {
        if isPressed { return Theme.cardPressed }
        return isHoverable && isHovering ? Theme.cardHover : Theme.card
    }
}
