import AppKit
import SwiftUI

/// Esc 处理：SwiftUI 的 `onExitCommand` 在 MenuBarExtra 窗口里拿不到焦点，
/// 这里用 local key monitor，且只在所在窗口是 key window 时生效。
@MainActor
struct EscapeKeyHandler: NSViewRepresentable {
    let model: PrototypeModel
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

@MainActor
final class EscapeCatcherView: NSView {
    var model: PrototypeModel?
    var onEscape: (() -> Void)?

    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitor()
        guard window != nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }

            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.window?.isKeyWindow == true else { return false }
                if let model = self.model, model.route != .root {
                    model.popToRoot()
                } else {
                    self.onEscape?()
                }
                return true
            }
            return handled ? nil : event
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopMonitor() }
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
