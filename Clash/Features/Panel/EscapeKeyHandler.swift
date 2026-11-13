import AppKit
import SwiftUI

/// Esc 处理：SwiftUI 的 `onExitCommand` 在 MenuBarExtra 窗口里拿不到焦点，
/// 这里用 local key monitor，且只在所在窗口是 key window 时生效。
@MainActor
struct EscapeKeyHandler: NSViewRepresentable {
    let model: PanelPreviewModel
    let onEscape: () -> Void

    func makeNSView(context: Context) -> EscapeCatcherView {
        let view = EscapeCatcherView()
        view.model = model
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ view: EscapeCatcherView, context: Context) {
        view.model = model
        view.onEscape = onEscape
    }
}
