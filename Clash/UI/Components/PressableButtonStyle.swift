import SwiftUI

/// 按下反馈：整块 0.98 缩放 + 注入 `isPressed`（胶囊 / 磁贴自行换更深的底）。
/// Reduce Motion 下不缩放，只保留底色变化（§5）。
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.isPressed, configuration.isPressed)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(
                reduceMotion
                    ? .easeInOut(duration: 0.15)
                    : .spring(response: 0.22, dampingFraction: 0.82),
                value: configuration.isPressed
            )
    }
}
