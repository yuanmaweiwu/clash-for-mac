import SwiftUI

/// 按下态：由 `PressableButtonStyle` 注入，胶囊 / 磁贴据此换更深的底（§2.2）。
///
/// 只传一个 Bool，不改变布局；拿不到注入时默认 false，独立预览也不会画错。
private struct PressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isPressed: Bool {
        get { self[PressedKey.self] }
        set { self[PressedKey.self] = newValue }
    }
}
