import SwiftUI

/// 演示窗口：模拟桌面壁纸 + 居中面板 + 右侧「原型控制」栏（面板外侧）。
/// 与状态栏浮层共享同一个模型，改动两边立即可见。
@MainActor
struct PrototypeRootView: View {
    let model: PrototypeModel

    var body: some View {
        ZStack {
            WallpaperView(tone: model.wallpaper)
                .ignoresSafeArea()

            PanelView(model: model)

            VStack {
                Spacer()
                sizeBadge
                    .padding(.bottom, 22)
            }

            HStack {
                Spacer()
                ControlRailView(model: model)
                    .padding(.trailing, 24)
            }
        }
        .frame(width: Metrics.windowWidth, height: Metrics.windowHeight)
        .preferredColorScheme(model.appearance.colorScheme)
    }

    /// 尺寸标注，方便肉眼核对宽度与圆角。
    private var sizeBadge: some View {
        HStack(spacing: 6) {
            Text("面板 340 × \(Int(model.displayedPanelHeight)) pt")
                .monospacedDigit()
            Text("圆角 12")
                .foregroundStyle(Theme.textTertiary)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background {
            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                .fill(Theme.opaque)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: Metrics.hairline)
        }
        .accessibilityHidden(true)
    }
}
