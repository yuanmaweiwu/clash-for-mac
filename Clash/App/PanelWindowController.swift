import AppKit
import OSLog
import QuartzCore
import SwiftUI

/// 面板窗口（`docs/adr/0011`）：自建 `NSPanel` 承载同一份 `PanelView`。
///
/// 系统原先由 `MenuBarExtra` 负责的尺寸、定位、失焦关闭都在这里补齐：
/// - 宽固定 340，高取内容 `fittingSize`（上限 656）
/// - 锚点对齐状态栏图标中心、距菜单栏 4pt，超出屏幕左右边界夹取
/// - 失焦（点外部 / 切 App）即收；`Esc` 由面板内容自己处理
@MainActor
final class PanelWindowController: NSObject, NSWindowDelegate {
    fileprivate static let logger = Logger(subsystem: "com.clash.app", category: "panel")
    /// 内容高度上限（`docs/02-UI-SPEC.md` §3.2：双卡满态 678，留 2pt 余量）
    private static let maximumHeight: CGFloat = Metrics.panelHeightMax
    /// 空态最小高（§3.2）
    private static let minimumHeight: CGFloat = 240
    /// 面板与菜单栏的间距
    private static let topGap: CGFloat = 4
    /// 夹取到屏幕边界时留的余量
    private static let screenInset: CGFloat = 8
    /// 同一次点击里「失焦关闭」与「按钮 action」的先后判定窗口
    private static let resignCoalesceInterval: TimeInterval = 0.3

    private let panel: PanelWindow
    private var hostingView: PanelHostingView<AnyView>!

    /// 面板显隐变化（状态栏按钮高亮恢复普通态）
    var onVisibilityChange: ((Bool) -> Void)?
    /// 最近一次失焦关闭的时间
    private var lastResignAt = Date.distantPast

    var isVisible: Bool { panel.isVisible }

    /// 面板刚因为这次点击失焦关掉（点状态栏图标时 `resignKey` 会先于按钮 action）
    var isVisibleRecently: Bool {
        Date().timeIntervalSince(lastResignAt) < Self.resignCoalesceInterval
    }

    init(model: PanelPreviewModel) {
        panel = PanelWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Metrics.panelWidth,
                height: Metrics.panelHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        configureWindow()

        let hosting = PanelHostingView(rootView: AnyView(
            PanelView(model: model, onClose: { [weak self] in self?.hide() })
        ))
        hosting.onContentSizeChange = { [weak self] _ in
            // 内容变高变矮（pin 切换 / 二级页）：窗口跟着改，保持顶边不动
            DispatchQueue.main.async {
                self?.resizeToFitContent()
            }
        }
        panel.contentView = hosting
        hostingView = hosting
    }

    private func configureWindow() {
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 失焦关闭由 `windowDidResignKey` 管；`hidesOnDeactivate` 保持关闭，
        // 否则切换 Space / 全屏时面板会被系统额外隐藏一次
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // MARK: - 显隐

    func show(relativeTo button: NSStatusBarButton?) {
        // 锚点取不到时不要静默 return：⌘, / 菜单唤起时若按钮还没进窗口，
        // 面板会"消失"或落到别处。这里退回屏幕右上角，保证位置可预期。
        let size = contentSize()
        let screen = button?.window?.screen ?? NSScreen.main
        var origin: NSPoint
        if let button, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            // 图标下方居中、距菜单栏 4pt
            origin = NSPoint(
                x: buttonFrame.midX - size.width / 2,
                y: buttonFrame.minY - Self.topGap - size.height
            )
        } else {
            let visible = screen?.visibleFrame ?? .zero
            origin = NSPoint(
                x: visible.maxX - size.width - Self.screenInset,
                y: visible.maxY - Self.topGap - size.height
            )
            Self.logger.notice("状态栏锚点不可用，面板退回屏幕右上角")
        }
        if let visible = screen?.visibleFrame {
            let minX = visible.minX + Self.screenInset
            let maxX = visible.maxX - Self.screenInset - size.width
            origin.x = min(max(origin.x, minX), max(minX, maxX))
            origin.y = max(origin.y, visible.minY + Self.screenInset)
        }

        Self.logger.notice("面板定位 x=\(origin.x, privacy: .public) y=\(origin.y, privacy: .public) 尺寸=\(size.width, privacy: .public)×\(size.height, privacy: .public) 屏幕=\(screen?.localizedName ?? "nil", privacy: .public)")
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
        // 面板刚显示时也补一次：路由可能是在隐藏状态下改的（⌘, / 菜单），
        // 隐着的时候没有绘制周期，内容还停在旧尺寸上
        syncHostingLayout()
        onVisibilityChange?(true)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        onVisibilityChange?(false)
    }

    private func resizeToFitContent() {
        guard panel.isVisible else { return }
        let height = contentSize().height
        let oldHeight = panel.frame.height

        // 兜底：`NSHostingView` 多数时候已经按内容极值把窗口改好了，没改到时我们自己改
        guard abs(oldHeight - height) > 0.5 else {
            // 尺寸没变也要补一次：`NSHostingView` 会在 SwiftUI 布局过程中按内容极值
            // 直接改窗口尺寸，那一次改动不会再驱动一轮完整布局，内容就停在旧尺寸的
            // 绘制结果上（订阅页 496 → 642 后整块空白的根因）。
            syncHostingLayout()
            return
        }

        // 顶边不动，只把底边往上/下推
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height

        // 先把目标位置夹进屏幕：动画结束后再夹会打断正在跑的窗口动画
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.y = max(frame.origin.y, visible.minY + Self.screenInset)
        }

        // 高度变化（pin 切换 / 二级页）用动画过渡，避免整块面板瞬间跳高跳矮。
        // Reduce Motion 下直接到位。
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
            clampToScreen()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor in self?.clampToScreen() }
            }
        }

        Self.logger.debug(
            "窗口高度 \(oldHeight, format: .fixed(precision: 1), privacy: .public) → \(height, format: .fixed(precision: 1), privacy: .public)"
        )

        // 布局对齐放在动画启动之后：内容按最终尺寸排一次，动画只负责窗口边框
        syncHostingLayout()
    }

    /// 强制把 SwiftUI 的布局与绘制跟窗口当前尺寸对齐。
    ///
    /// `NSHostingView` 会在自己的布局过程中（`updateWindowContentSizeExtrema`）直接改窗口
    /// 尺寸，而那次改动之后不会再补一轮布局：SwiftUI 的树仍停在旧高度，绘制结果也是旧的，
    /// 于是窗口变高了却整块空白（订阅页 496 → 642 就是这样）。补一轮 layout + display
    /// 就能让内容跟上；代价只是一次小面板重绘。
    private func syncHostingLayout() {
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        hostingView.needsDisplay = true
        hostingView.displayIfNeeded()
    }

    /// 屏幕边缘 / 分辨率变化后仍要保证整块面板可见
    private func clampToScreen() {
        guard let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        var frame = panel.frame
        let minX = visible.minX + Self.screenInset
        let maxX = visible.maxX - Self.screenInset - frame.width
        frame.origin.x = min(max(frame.origin.x, minX), max(minX, maxX))
        frame.origin.y = max(frame.origin.y, visible.minY + Self.screenInset)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
        }
    }

    private func contentSize() -> NSSize {
        hostingView.layoutSubtreeIfNeeded()
        let fittingHeight = hostingView.fittingSize.height
        // 测不到极值（过渡帧 / 空树）时沿用当前高度：回落到 642 会让面板瞬间跳高
        let fallbackHeight = panel.frame.height > 0 ? panel.frame.height : Metrics.panelHeight
        let height = fittingHeight > 0 ? fittingHeight : fallbackHeight
        return NSSize(
            width: Metrics.panelWidth,
            height: min(max(height, Self.minimumHeight), Self.maximumHeight)
        )
    }

    // MARK: - NSWindowDelegate

    /// 点面板外部（别的 App / 桌面）就收起来
    func windowDidResignKey(_ notification: Notification) {
        lastResignAt = Date()
        hide()
    }

    /// 面板内容自己 `window.close()`（例如打开日志窗口后）也要恢复按钮普通态
    func windowWillClose(_ notification: Notification) {
        lastResignAt = Date()
        onVisibilityChange?(false)
    }
}

/// 无边框浮层面板：`nonactivatingPanel` 不抢 App 激活，但仍要能成为 key 窗口，
/// 否则 Esc、⌘Q 与面板内的键盘交互都收不到。
private final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// LSUIElement 应用没有可见主菜单：⌘Q / ⌘, 在这里兜一层，保证面板聚焦时可用
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "q":
            NSApp.terminate(nil)
            return true
        case ",":
            AppEnvironment.shared.showSettingsPage()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// 内容尺寸变化回调：`NSPanel` 没有 `MenuBarExtra` 的自动调整，只能自己跟
private final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var onContentSizeChange: ((CGSize) -> Void)?
    private var lastReportedSize = CGSize.zero
    /// `fittingSize` 会再入 SwiftUI 布局：同一轮里只测一次，避免自激
    private var isMeasuring = false

    override func layout() {
        super.layout()
        measureContentSize()
    }

    private func measureContentSize() {
        guard !isMeasuring else { return }
        isMeasuring = true
        defer { isMeasuring = false }

        let size = fittingSize
        guard size != lastReportedSize else { return }
        PanelWindowController.logger.debug(
            "内容高度 \(self.lastReportedSize.height, format: .fixed(precision: 1), privacy: .public) → \(size.height, format: .fixed(precision: 1), privacy: .public)"
        )
        lastReportedSize = size
        onContentSizeChange?(size)
    }
}
