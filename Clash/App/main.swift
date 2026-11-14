import AppKit

/// App 入口：纯 AppKit（`docs/adr/0011`）。
///
/// 窗口全部由 AppKit 持有（状态栏 + 面板 + 日志），SwiftUI 只做视图层，
/// 因此不再需要任何 `Scene`。以前为了满足「`App` 至少一个 `Scene`」留了
/// `Settings { EmptyView() }`，SwiftUI 会给它注册 ⌘, 并弹出一个空窗口，
/// 抢在 `AppDelegate` 的主菜单项之前——改成 AppKit 入口后这条路径彻底消失。
///
/// `main.swift` 的顶层代码在 Swift 6 里已是 `@MainActor`，可以直接构建 `@MainActor` 类型。
// 单实例：菜单栏应用只允许一个进程。重复启动（Launchpad 连点 / `open -n` / 测试脚本）
// 会把前一个实例隐藏起来，并让两个实例抢同一套 helper / 端口 / TUN 内核。
// 自检夹具（`CLASH_*` 环境变量）例外：它们不承载用户会话，需要与正式实例并存做截图/测量。
let environment = ProcessInfo.processInfo.environment
let isFixtureLaunch = environment.keys.contains { $0.hasPrefix("CLASH_") }
if !isFixtureLaunch,
   let identity = Bundle.main.bundleIdentifier,
   let other = NSRunningApplication.runningApplications(withBundleIdentifier: identity)
       .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    other.activate(options: [.activateIgnoringOtherApps])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// `LSUIElement` 已在 Info.plist；这里再兜一次，避免以 Dock 图标形态启动
_ = app.setActivationPolicy(.accessory)
app.run()
