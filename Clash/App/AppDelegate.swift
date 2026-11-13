import AppKit
import OSLog

/// App 级入口：状态栏图标 + 最小主菜单（`docs/adr/0011`）。
///
/// `LSUIElement` 应用没有 Dock 图标：设置与添加订阅都在面板内，独立窗口只剩「日志」。
/// 状态栏图标由本类持有，生命周期与进程一致。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.clash.app", category: "app")

    private var statusItemController: StatusItemController?

    /// 菜单栏应用不应该在启动时恢复上次的窗口（尤其是日志窗口）。
    /// 在窗口恢复之前清掉 saved state；同时把日志窗口自身标记为不可恢复（双保险）。
    func applicationWillFinishLaunching(_ notification: Notification) {
        let savedState = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Saved Application State", isDirectory: true)
            .appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "com.clash.app").savedState", isDirectory: true)
        if let savedState, FileManager.default.fileExists(atPath: savedState.path) {
            try? FileManager.default.removeItem(at: savedState)
            Self.logger.info("已清除上次窗口状态，避免日志窗口随启动弹出")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // 截图走查：设了 CLASH_PREVIEW_PAGE 就只摆夹具窗口，不创建状态栏 / 内核
        if UIPreviewHarness.runIfRequested() { return }
        #endif
        installMainMenu()
        let environment = AppEnvironment.shared
        statusItemController = StatusItemController(model: environment.model, panel: environment.panel)
        Self.logger.info("状态栏图标已创建（左键面板 / 右键菜单）")
    }

    /// 关掉日志窗口不退出：状态栏应用只在「退出 Clash」/ ⌘Q 时退
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - 最小主菜单

    /// `LSUIElement` 没有可见菜单栏，但 key equivalent 仍走主菜单：
    /// 补一个最小的，面板/窗口聚焦时 ⌘Q、⌘,、⌘W 才有效。
    /// 「退出 Clash」的 action 是 `NSApplication.terminate(_:)`，
    /// 与右键菜单同一条路径 → `applicationWillTerminate` → `AppTerminationGuard`。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Clash")

        let settingsItem = appMenu.addItem(
            withTitle: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self

        appMenu.addItem(.separator())

        let quitItem = appMenu.addItem(
            withTitle: "退出 Clash",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenuItem.submenu = appMenu

        // 设置窗口里有文本框：没有编辑菜单 ⌘C/⌘V/⌘A 全部失效
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        addEditItem(editMenu, title: "撤销", selector: Selector(("undo:")), key: "z")
        addEditItem(editMenu, title: "重做", selector: Selector(("redo:")), key: "z", modifiers: [.command, .shift])
        editMenu.addItem(.separator())
        addEditItem(editMenu, title: "剪切", selector: #selector(NSText.cut(_:)), key: "x")
        addEditItem(editMenu, title: "拷贝", selector: #selector(NSText.copy(_:)), key: "c")
        addEditItem(editMenu, title: "粘贴", selector: #selector(NSText.paste(_:)), key: "v")
        addEditItem(editMenu, title: "全选", selector: #selector(NSText.selectAll(_:)), key: "a")
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        let closeItem = windowMenu.addItem(
            withTitle: "关闭",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeItem.target = nil
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func addEditItem(
        _ menu: NSMenu,
        title: String,
        selector: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) {
        let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
    }

    /// 「设置…」现在是面板内的二级页：叫出面板 + 推入设置页
    @objc private func openSettings() {
        AppEnvironment.shared.showSettingsPage()
    }
}
