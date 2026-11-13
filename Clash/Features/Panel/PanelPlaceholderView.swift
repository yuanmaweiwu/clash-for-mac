import SwiftUI

/// 状态栏浮层占位：真实面板从 `Prototype/` 迁入，v0.1 先固定尺寸。
@MainActor
struct PanelPlaceholderView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
            Text("面板待移植")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(width: 340, height: 200)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    PanelPlaceholderView()
}
