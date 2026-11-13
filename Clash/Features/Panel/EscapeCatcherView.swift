import AppKit

/// 挂在面板上的 AppKit 视图：只负责接收 Esc，再交回面板的导航逻辑。
@MainActor
final class EscapeCatcherView: NSView {
    var model: PanelPreviewModel?
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
                    model.popRoute()
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
