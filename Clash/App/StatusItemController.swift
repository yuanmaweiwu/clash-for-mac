import AppKit
import OSLog

/// 状态栏图标 + 右键菜单（`docs/adr/0011`）。
///
/// 左键：开/关面板；右键：`NSMenu`（日志 / 退出）。设置走面板内页与 ⌘,。
/// 图标语义只有一个：**是否正在接管流量**（`docs/02-UI-SPEC.md` §4.1）——
/// 未运行 = 描边 + 45° 斜线，已就绪 = 描边，代理中 / TUN = 实心，失败 = 实心 + 右下红点。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let logger = Logger(subsystem: "com.clash.app", category: "statusitem")

    /// 图标绘制盒 18×18pt（§4.1）
    private static let iconSide: CGFloat = 18
    /// 失败红点直径（全组件唯一允许的彩色）
    private static let failureDotDiameter: CGFloat = 4

    private let model: PanelPreviewModel
    private let panel: PanelWindowController
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let failureDot: NSView

    init(model: PanelPreviewModel, panel: PanelWindowController) {
        self.model = model
        self.panel = panel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        menu = NSMenu()
        failureDot = NSView()

        super.init()

        // 面板的锚点与显隐入口都在 App 组合根上：⌘, / 菜单项 / 左键共用同一条路径
        AppEnvironment.shared.statusItemAnchor = { [weak self] in self?.statusItem.button }
        // 失焦时判断是不是点在图标上（同一次点击里 `resignKey` 会先于按钮 action）
        panel.isMouseOverStatusItem = { [weak self] in
            guard let self, let button = self.statusItem.button, let window = button.window else {
                return false
            }
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            return frame.contains(NSEvent.mouseLocation)
        }
        panel.onVisibilityChange = { [weak self] isVisible in
            // 收起时停止把流量采样发布给 UI（隐藏窗口不重绘），打开时一次补齐
            self?.model.setPanelVisible(isVisible)
            self?.setButtonHighlighted(isVisible)
        }

        buildMenu()
        buildButton()
        refresh()
        observeModel()
    }

    // MARK: - 按钮

    private func buildButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick)
        // 左键在 mouseUp 才算点击：失焦关闭要先发生，toggle 才拿得到真实可见性
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        failureDot.wantsLayer = true
        failureDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        failureDot.layer?.cornerRadius = Self.failureDotDiameter / 2
        failureDot.isHidden = true
        failureDot.frame = NSRect(
            x: button.bounds.width - Self.failureDotDiameter - 2,
            y: 1,
            width: Self.failureDotDiameter,
            height: Self.failureDotDiameter
        )
        // 图标长度会随速率文字变化：红点始终贴右下角
        failureDot.autoresizingMask = [.minXMargin, .maxYMargin]
        button.addSubview(failureDot)

        button.setAccessibilityLabel("Clash")
        button.setAccessibilityHelp("打开控制面板")
    }

    /// 状态 + 图标 + 可访问性一起刷新（观察 `model` 后自动回调）
    private func refresh() {
        let state = resolveIconState()
        statusItem.button?.image = makeIconImage(for: state)
        statusItem.button?.setAccessibilityValue(model.status.title)
        failureDot.isHidden = state != .failed
    }

    /// 图标只表达「是否在接管流量」：TUN 与系统代理任一开着就是实心（§4.1）
    private func resolveIconState() -> StatusIconState {
        if model.status == .failed {
            return .failed
        }
        if model.status == .idle || model.status == .starting {
            return .idle
        }
        if model.isSystemProxyOn || model.isTunOn {
            return .engaged
        }
        return .ready
    }

    /// 模板图：描边 / 实心剪影 + 未运行斜线，红点由子视图叠在右下角
    private func makeIconImage(for state: StatusIconState) -> NSImage {
        let side = Self.iconSide
        let isFilled = state == .engaged || state == .failed
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let symbolName = isFilled ? "power.circle.fill" : "power.circle"
            let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            else { return false }

            let symbolSize = symbol.size
            let origin = NSPoint(
                x: (side - symbolSize.width) / 2,
                y: (side - symbolSize.height) / 2
            )
            symbol.draw(
                in: NSRect(origin: origin, size: symbolSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )

            if state == .idle {
                let slash = NSBezierPath()
                slash.lineWidth = 1.5
                slash.lineCapStyle = .round
                slash.move(to: NSPoint(x: 3.5, y: 3.5))
                slash.line(to: NSPoint(x: side - 3.5, y: side - 3.5))
                NSColor.black.setStroke()
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setButtonHighlighted(_ isHighlighted: Bool) {
        statusItem.button?.highlight(isHighlighted)
    }

    // MARK: - 观察

    /// `@Observable` 没有 Combine：`withObservationTracking` 单次回调，重新挂上才持续生效
    private func observeModel() {
        withObservationTracking {
            _ = model.status
            _ = model.isSystemProxyOn
            _ = model.isTunOn
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observeModel()
            }
        }
    }

    // MARK: - 点击

    @objc private func handleStatusItemClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        let isVisible = panel.isVisible
        // 先取走「刚被这次点击失焦关掉」的标记：用过即清，不会跨点击累积
        let justResigned = panel.consumeResignClose()
        Self.logger.notice(
            "左键 toggle：面板可见=\(isVisible, privacy: .public) 刚失焦关闭=\(justResigned, privacy: .public)"
        )
        if isVisible {
            Self.logger.notice("左键 toggle → 收起面板")
            panel.hide()
        } else if justResigned {
            // 这次点击刚把面板弄失焦（点状态栏图标时 `resignKey` 先于按钮 action）→ 按「关」处理
            Self.logger.notice("状态栏点击与失焦关闭重合，按关闭处理")
        } else {
            Self.logger.notice("左键 toggle → 打开面板")
            AppEnvironment.shared.showPanel()
        }
    }

    // MARK: - 菜单

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        let logsItem = NSMenuItem(title: "日志", action: #selector(openLogs), keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Clash", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func showMenu() {
        // 右键时面板若还开着：先收起，菜单与面板不叠在一起
        panel.hide()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // 菜单关掉后必须摘掉，否则左键也会弹菜单
        statusItem.menu = nil
    }



    /// 设置现在是面板内的二级页：叫出面板 + 推入设置页（与 ⌘, 同一入口）
    @objc private func openSettings() {
        AppEnvironment.shared.showSettingsPage()
    }

    @objc private func openLogs() {
        AppEnvironment.shared.openLogsWindow()
    }

    /// 走 `NSApp.terminate` → `applicationWillTerminate` → `AppTerminationGuard`
    /// （撤代理 → 停 TUN / 本地内核）。**禁止 `exit(0)`**，会绕过清理。
    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// 图标只表达「是否在接管流量」，与 `docs/02-UI-SPEC.md` §4.1 一致
private enum StatusIconState {
    /// 未运行 / 启动中：描边 + 45° 斜线
    case idle
    /// 运行 · 未接管：描边
    case ready
    /// 代理中（系统代理或 TUN）：实心
    case engaged
    /// 失败：实心 + 右下红点
    case failed
}
