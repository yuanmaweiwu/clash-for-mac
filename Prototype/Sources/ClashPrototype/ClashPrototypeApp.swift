import AppKit
import SwiftUI

@main
struct ClashPrototypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 状态栏浮层与演示窗口共享同一个模型
    @State private var model = PrototypeModel()

    var body: some Scene {
        MenuBarExtra {
            PanelPopoverView(model: model)
        } label: {
            MenuBarStatusLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Clash 面板原型", id: DemoWindowID.demo) {
            PrototypeRootView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: Metrics.windowWidth, height: Metrics.windowHeight)
        .defaultLaunchBehavior(.presented)
        .commands {
            // 原型只要一个窗口，去掉「新建窗口」
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if PrototypeSnapshot.runIfRequested() {
            exit(0)
        }
        if PrototypeSelfTest.runIfRequested() {
            return
        }
        measureIfRequested()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关掉演示窗口后仍保留状态栏图标，不退出 App
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// `swift run ClashPrototype --measure`：打印面板自然尺寸后立即退出，
    /// 用于无人值守核对 340 × 626 的落地情况。
    private func measureIfRequested() {
        guard CommandLine.arguments.contains("--measure") else { return }

        let pinned = PrototypeModel()
        pinned.pinAllGroups()
        let pinnedBanner = PrototypeModel()
        pinnedBanner.pinAllGroups()
        pinnedBanner.enterFailedState()
        let empty = PrototypeModel()
        empty.showsEmptyState = true
        let emptyBanner = PrototypeModel()
        emptyBanner.showsEmptyState = true
        emptyBanner.showsErrorBanner = true

        let cases: [(String, PrototypeModel)] = [
            ("单卡", PrototypeModel()),
            ("双卡", pinned),
            ("双卡 + banner", pinnedBanner),
            ("空态", empty),
            ("空态 + banner", emptyBanner),
            ("二级：订阅", { let model = PrototypeModel(); model.route = .subscriptions; return model }())
        ]

        for (name, model) in cases {
            let host = NSHostingView(rootView: PanelView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 480, height: 900)
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            print("\(name)：\(Int(size.width.rounded())) x \(Int(size.height.rounded())) pt")
        }
        exit(0)
    }
}
