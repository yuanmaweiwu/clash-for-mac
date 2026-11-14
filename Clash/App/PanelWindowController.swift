import AppKit
import OSLog
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
    /// SwiftUI 树第一次上屏时才建（见 `ensureContentView`）：挂上 `NSHostingView`
    /// 会立刻拉起 SwiftUI 的 Metal 表面池，不为从没打开过的面板付这份钱
    private var hostingView: PanelHostingView<AnyView>?
    private let model: PanelPreviewModel

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
        self.model = model
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

        // 面板建好就是隐藏状态：先把「不可见」交给模型，避免每秒采样推着隐藏窗口离屏重绘
        model.setPanelVisible(false)
    }

    /// 首次显示时才把 SwiftUI 树挂到窗口上。
    ///
    /// `NSHostingView` 一挂上就会初始化 SwiftUI 的 Metal 渲染表面池：实测启动后 1s
    /// footprint 96MB（其中 56MB 是 `IOAccelerator (graphics)`），几秒后虽然回收，
    /// 峰值已经留在 `phys_footprint_peak` 上了。菜单栏应用绝大多数时间是「挂着不打开」，
    /// 这份钱应该等到真正上屏再付。
    private func ensureContentView() {
        guard hostingView == nil else { return }

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
        ensureContentView()
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
        // 先把流量缓冲补进模型，再上屏：首帧就是完整波形，不会闪一下「暂无流量」
        onVisibilityChange?(true)
        // 定位这一下可能有高度变化：先把锚点清掉，落位后再记新的顶边
        panel.topAnchor = nil
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.topAnchor = origin.y + size.height
        panel.makeKeyAndOrderFront(nil)
        // 面板刚显示时也补一次：路由可能是在隐藏状态下改的（⌘, / 菜单），
        // 隐着的时候没有绘制周期，内容还停在旧尺寸上
        syncHostingLayout()
        #if DEBUG
        printCaptureRegionIfRequested(screen: screen)
        #endif
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // 下屏之后再清空：清空状态一帧都不用画
        onVisibilityChange?(false)
    }

    private func resizeToFitContent() {
        guard panel.isVisible else { return }
        let height = contentSize().height
        let oldHeight = panel.frame.height

        // 兜底：`NSHostingView` 多数时候已经按内容极值把窗口改好了，没改到时我们自己改
        guard abs(oldHeight - height) > 0.5 else {
            // 高度已被 `NSHostingView` 自己改好（它按底边锚），把顶边钉回锚点；
            // 顺带补一轮布局：那次改动不会再驱动完整布局，内容会停在旧尺寸的绘制结果上
            if let top = panel.topAnchor, abs(panel.frame.maxY - top) > 0.5 {
                var frame = panel.frame
                frame.origin.y = top - frame.height
                panel.setFrame(frame, display: true)
            }
            syncHostingLayout()
            return
        }

        // 顶边不动，只把底边往上/下推。锚点用 show 时记下的那条，
        // 不能读 `panel.frame.maxY`：NSHostingView 可能已经按底边改过一次窗口。
        var frame = panel.frame
        frame.size.height = height
        frame.origin.y = (panel.topAnchor ?? frame.maxY) - height

        // 先把目标位置夹进屏幕，避免瞬改后有一帧落到屏幕外
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.y = max(frame.origin.y, visible.minY + Self.screenInset)
        }

        // 高度切换必须与 SwiftUI 内容同帧完成：面板背景的 16pt 圆角由内容自己画，
        // 一旦窗口动画比内容慢，中间帧就会在四角露出直角（实测 6 帧、约 300ms）。
        panel.setFrame(frame, display: true)
        clampToScreen()

        Self.logger.debug(
            "窗口高度 \(oldHeight, format: .fixed(precision: 1), privacy: .public) → \(height, format: .fixed(precision: 1), privacy: .public)"
        )

        // 尺寸瞬改后补一轮布局：SwiftUI 的树要按新高度排一次，避免停在旧绘制结果上
        syncHostingLayout()
        #if DEBUG
        printCaptureRegionIfRequested(screen: panel.screen)
        #endif
    }

    #if DEBUG
    /// 截图走查（仅 Debug）：`CLASH_CAPTURE_REGION=1` 时把窗口区域打到 stdout，
    /// 外部用 `screencapture -R` 直接沿用（坐标原点与 `screencapture` 一致，在左上）。
    private func printCaptureRegionIfRequested(screen: NSScreen?) {
        guard ProcessInfo.processInfo.environment["CLASH_CAPTURE_REGION"] == "1" else { return }
        let screenHeight = screen?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let frame = panel.frame
        print("CLASH_PANEL_REGION \(Int(frame.minX)),\(Int(screenHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))")
        fflush(stdout)
    }
    #endif

    /// 强制把 SwiftUI 的布局与绘制跟窗口当前尺寸对齐。
    ///
    /// `NSHostingView` 会在自己的布局过程中（`updateWindowContentSizeExtrema`）直接改窗口
    /// 尺寸，而那次改动之后不会再补一轮布局：SwiftUI 的树仍停在旧高度，绘制结果也是旧的，
    /// 于是窗口变高了却整块空白（订阅页 496 → 642 就是这样）。补一轮 layout + display
    /// 就能让内容跟上；代价只是一次小面板重绘。
    private func syncHostingLayout() {
        guard let hostingView else { return }
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
            panel.topAnchor = frame.maxY
        }
    }

    private func contentSize() -> NSSize {
        // `show` 里先 `ensureContentView()` 再调这里；真有路径漏了就直接用默认高度
        guard let hostingView else {
            return NSSize(width: Metrics.panelWidth, height: Metrics.panelHeight)
        }
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

    /// `NSHostingView` 自己改窗口尺寸时可能不走 `setFrame`（内部路径），
    /// 这里兜一层：高度变了就把顶边钉回锚点，防止面板在一帧里上下跳。
    func windowDidResize(_ notification: Notification) {
        guard let top = panel.topAnchor, abs(panel.frame.maxY - top) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = top - frame.height
        panel.setFrame(frame, display: true)
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
    /// 高度变化时保持的顶边（屏幕坐标）。`NSHostingView` 自己按内容极值改窗口尺寸时
    /// 默认锚在底边，会把面板整体顶下去一帧；记下顶边后任何 resize 都钉住它。
    var topAnchor: CGFloat?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if let topAnchor, abs(rect.height - frame.height) > 0.5 {
            rect.origin.y = topAnchor - rect.height
        }
        super.setFrame(rect, display: flag)
    }

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
