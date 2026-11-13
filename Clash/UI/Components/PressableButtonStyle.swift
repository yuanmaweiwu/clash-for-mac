import SwiftUI

/// 按下 0.98 缩放（§5 motion/tile）；Reduce Motion 下不缩放。
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(
                reduceMotion
                    ? .easeInOut(duration: 0.15)
                    : .spring(response: 0.28, dampingFraction: 0.80),
                value: configuration.isPressed
            )
    }
}
