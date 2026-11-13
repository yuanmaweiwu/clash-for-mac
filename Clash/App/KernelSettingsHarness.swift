#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// 设置 → 内核的联动自检（仅 DEBUG）：`CLASH_KERNEL_HARNESS=<mode>` 时在 UI 起来前跑并退出。
///
/// 模式：
/// - `port-log`：设置端口 17890 + 日志级别 debug → 起内核 → 校验 `runtime.yaml`、
///   `lsof` 监听、内核日志里的 debug 级别、`/logs?level=debug` 帧；最后改回 7890 / info
/// - `keep-kernel-off`：`keepKernelOnProxyOff=false` 时关代理必须一并停内核
/// - `corrupt`：把真实 `settings.json` 改坏 → 启动后回默认并生成 `settings.corrupt-*.json`，
///   验证完把原文件写回去
/// - `panel-pages`：设置页 / 添加订阅页的路由与导入状态（临时目录，不联网）
/// - `settings-port-restart`：改端口 → 「需要重启内核生效」→ 立即重启 → `runtime.yaml` 端口变化
@MainActor
enum KernelSettingsHarness {

    static func runIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["CLASH_KERNEL_HARNESS"], !mode.isEmpty else {
            return
        }

        var failures = 0
        var finished = false
        Task { @MainActor in
            failures = await run(mode: mode)
            finished = true
        }

        let deadline = Date().addingTimeInterval(180)
        while !finished && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        print(finished ? "HARNESS DONE failures=\(failures)" : "HARNESS TIMEOUT")
        exit(finished ? (failures == 0 ? 0 : 1) : 2)
    }

    private static func report(_ name: String, _ passed: Bool, _ detail: String = "") -> Int {
        print(passed ? "PASS \(name)" : "FAIL \(name) \(detail)")
        return passed ? 0 : 1
    }

    private static func run(mode: String) async -> Int {
        switch mode {
        case "port-log": return await runPortAndLog()
        case "keep-kernel-off": return await runKeepKernelOff()
        case "corrupt": return await runCorruptRealFile()
        case "login": return await runLoginItem()
        case "panel-pages": return await runPanelPages()
        case "settings-port-restart": return await runSettingsPortRestart()
        default:
            print("FAIL unknown-mode \(mode)")
            return 1
        }
    }

    // MARK: - 面板内两个新页面（路由 / 导入态）

    private static func runPanelPages() async -> Int {
        var failures = 0
        let root = FileManager.default.temporaryDirectory
            .appending(path: "clash-panel-harness-\(UUID().uuidString)", directoryHint: .isDirectory)
        let settings = SettingsStore(fileURL: root.appending(path: "settings.json"))
        let store = ProfileStore(directory: root.appending(path: "profiles"))
        let model = PanelPreviewModel(profileStore: store, settings: settings, autoStartsKernel: false)

        // 1. 设置页：推入 / 返回
        model.openSettingsPage()
        failures += report("route-settings", model.route == .settings, "route=\(model.route)")
        model.popRoute()
        failures += report("route-settings-back", model.route == .root, "route=\(model.route)")

        // 2. 添加订阅：订阅页 → 添加页；Esc 逐层退（popRoute 同路径）
        model.openSubscriptions()
        model.openSubscriptionNewPage()
        failures += report("route-subscription-new", model.route == .subscriptionNew, "route=\(model.route)")

        // 坏 URL：错误留在页内，不跳转
        model.importSubscription(urlString: "不是链接")
        await waitUntil(timeout: 30) { !model.isImportingProfile }
        failures += report(
            "import-error-shown",
            model.importError != nil,
            "error=\(model.importError ?? "-")"
        )
        failures += report(
            "import-error-stays-on-page",
            model.route == .subscriptionNew,
            "route=\(model.route)"
        )

        model.popRoute()
        failures += report(
            "route-subscription-new-back",
            model.route == .subscriptions,
            "route=\(model.route)"
        )

        // 3. 本地 YAML 成功：回订阅列表 + 高亮新项
        model.openSubscriptionNewPage()
        let yamlURL = root.appending(path: "harness.yaml")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? """
        mixed-port: 7890
        proxies: []
        proxy-groups: []
        rules:
          - MATCH,DIRECT
        """.write(to: yamlURL, atomically: true, encoding: .utf8)

        model.importLocalSubscription(fileURL: yamlURL)
        await waitUntil(timeout: 120) { !model.isImportingProfile }
        failures += report(
            "local-import-succeeds",
            store.entries.count == 1,
            "count=\(store.entries.count) err=\(model.importError ?? "-")"
        )
        failures += report(
            "local-import-returns-to-list",
            model.route == .subscriptions,
            "route=\(model.route)"
        )
        failures += report(
            "local-import-highlighted",
            model.recentlyImportedProfileID == store.entries.first?.id,
            "highlight=\(model.recentlyImportedProfileID ?? "-")"
        )

        // 4. 两个页面能真的布出来（316 = 340 面板宽减左右 12pt；高度 618 与其它二级页一致）
        let settingsView = NSHostingView(
            rootView: SettingsPanelView(model: model, settings: settings, onBack: {})
        )
        settingsView.frame = NSRect(x: 0, y: 0, width: 316, height: 618)
        settingsView.layoutSubtreeIfNeeded()
        failures += report(
            "settings-view-layout",
            settingsView.fittingSize.width == 316 && settingsView.fittingSize.height == 618,
            "fitting=\(settingsView.fittingSize)"
        )

        model.openSubscriptionNewPage()
        let newView = NSHostingView(rootView: SubscriptionNewPanelView(model: model, onBack: {}))
        newView.frame = NSRect(x: 0, y: 0, width: 316, height: 618)
        newView.layoutSubtreeIfNeeded()
        failures += report(
            "subscription-new-view-layout",
            newView.fittingSize.width == 316 && newView.fittingSize.height == 618,
            "fitting=\(newView.fittingSize)"
        )

        try? FileManager.default.removeItem(at: root)
        return failures
    }

    // MARK: - 端口改动 → 需要重启 → 立即重启

    private static func runSettingsPortRestart() async -> Int {
        var failures = 0
        let settings = SettingsStore()
        let original = settings.mixedPort
        print("NOTE original port=\(original)")

        let kernel = KernelService(settings: settings)
        let model = PanelPreviewModel(kernel: kernel, settings: settings, autoStartsKernel: false)

        await kernel.start()
        failures += report(
            "kernel-running",
            kernel.phase == .running,
            "phase=\(kernel.phase) err=\(kernel.lastError?.userMessage ?? "-")"
        )
        failures += report("no-restart-needed-before", !model.needsKernelRestartForSettings)

        let newPort = 17891
        settings.mixedPort = newPort
        failures += report("restart-needed-after-port-change", model.needsKernelRestartForSettings)

        model.restartKernelForSettings()
        await waitUntil(timeout: 90) { !model.isApplyingSettings && kernel.activeMixedPort == newPort }
        failures += report("restart-applied", kernel.activeMixedPort == newPort, "active=\(kernel.activeMixedPort ?? -1)")

        let runtime = (try? String(contentsOf: AppPaths.runtimeConfigURL, encoding: .utf8)) ?? ""
        failures += report("runtime-mixed-port", runtime.contains("mixed-port: \(newPort)"))

        // 还原：端口写回原值并再重启一次，别把测试痕迹留在真实设置里
        settings.mixedPort = original
        model.restartKernelForSettings()
        await waitUntil(timeout: 90) { !model.isApplyingSettings && kernel.activeMixedPort == original }
        failures += report("restored-port", kernel.activeMixedPort == original, "active=\(kernel.activeMixedPort ?? -1)")

        await kernel.stop()
        return failures
    }

    /// 等一个条件成立（主线程不阻塞：harness 已经在 MainActor 的 Task 里）
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - 端口 / 日志级别

    private static func runPortAndLog() async -> Int {
        var failures = 0
        let settings = SettingsStore()
        let original = settings.values
        print("NOTE original port=\(original.mixedPort) level=\(original.logLevel.rawValue)")

        // 改端口与日志级别（与设置窗口写入走同一条路径）
        settings.mixedPort = 17890
        settings.logLevel = .debug
        settings.allowLAN = true

        let kernel = KernelService(settings: settings)
        await kernel.start()
        failures += report(
            "kernel-running",
            kernel.phase == .running,
            "phase=\(kernel.phase) err=\(kernel.lastError?.userMessage ?? "-")"
        )
        print("NOTE kernel active port=\(kernel.activeMixedPort ?? -1) level=\(kernel.activeLogLevel ?? "-")")

        let runtime = (try? String(contentsOf: AppPaths.runtimeConfigURL, encoding: .utf8)) ?? ""
        let keys = runtime
            .split(separator: "\n")
            .filter { $0.hasPrefix("mixed-port") || $0.hasPrefix("log-level") || $0.hasPrefix("allow-lan") }
            .joined(separator: " | ")
        print("NOTE runtime keys: \(keys)")
        failures += report("runtime-mixed-port", runtime.contains("mixed-port: 17890"))
        failures += report("runtime-log-level", runtime.contains("log-level: debug"))
        failures += report("runtime-allow-lan", runtime.contains("allow-lan: true"))
        failures += report("runtime-allow-lan-no-bind", !runtime.contains("bind-address:"))

        let listening = await shell("/usr/sbin/lsof", ["-nP", "-iTCP:17890", "-sTCP:LISTEN"])
        print("NOTE lsof 17890:\n\(listening)")
        failures += report("port-listening", listening.contains("LISTEN"))

        // 内核日志文件：debug 级别生效后应出现 level=debug 行
        let logText = latestLogText()
        failures += report("kernel-log-has-debug", logText.contains("level=debug"))

        // `/logs?level=debug` WS：只报告收到哪些级别（静默期内可能没有新帧）
        if let port = kernel.port, let secret = kernel.secret {
            let client = ClashAPIClient(port: port, secret: secret)
            let stream = await client.logs(level: "debug")
            var levels = Set<String>()
            let sink = Task {
                for try await line in stream {
                    levels.insert(line.level.rawValue)
                }
            }
            try? await Task.sleep(for: .seconds(6))
            sink.cancel()
            await client.stopLogs()
            print("NOTE ws levels=\(levels.sorted().joined(separator: ","))")
            failures += report("ws-debug-level", levels.contains("debug"))
        }

        await kernel.stop()
        failures += report("kernel-stopped", kernel.phase == .stopped, "phase=\(kernel.phase)")

        // 改回原值，保证验收结束后设置与 UI 一致
        settings.mixedPort = original.mixedPort
        settings.logLevel = original.logLevel
        settings.allowLAN = original.allowLAN
        let reverted = SettingsStore()
        failures += report("reverted-port", reverted.mixedPort == original.mixedPort, "port=\(reverted.mixedPort)")
        failures += report("reverted-level", reverted.logLevel == original.logLevel)
        print("NOTE reverted settings: \(reverted.values)")
        return failures
    }

    // MARK: - 关代理是否停内核

    private static func runKeepKernelOff() async -> Int {
        var failures = 0
        let settings = SettingsStore()
        let original = settings.values
        settings.keepKernelOnProxyOff = false

        let kernel = KernelService(settings: settings)
        let systemProxy = SystemProxyService()
        let model = PanelPreviewModel(
            kernel: kernel,
            systemProxy: systemProxy,
            settings: settings,
            autoStartsKernel: false
        )

        model.toggleConnection()
        var waited = 0.0
        while waited < 60, !model.isSystemProxyOn {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 0.2
        }
        failures += report(
            "proxy-on",
            model.isSystemProxyOn,
            "on=\(model.isSystemProxyOn) err=\(model.errorMessage ?? "-")"
        )

        model.toggleConnection()
        waited = 0.0
        while waited < 60, model.isSystemProxyOn {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 0.2
        }
        failures += report("proxy-off", !model.isSystemProxyOn)

        waited = 0.0
        while waited < 20, kernel.phase != .stopped {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 0.2
        }
        failures += report("kernel-stopped-with-proxy", kernel.phase == .stopped, "phase=\(kernel.phase)")

        settings.keepKernelOnProxyOff = original.keepKernelOnProxyOff
        return failures
    }

    // MARK: - 开机自启（真实 SMAppService 状态）

    private static func runLoginItem() async -> Int {
        var failures = 0
        print("NOTE login status-before=\(LaunchAtLogin.statusText) enabled=\(LaunchAtLogin.isEnabled)")

        do {
            try LaunchAtLogin.setEnabled(true)
            print("NOTE register ok status=\(LaunchAtLogin.statusText) enabled=\(LaunchAtLogin.isEnabled)")
        } catch {
            print("NOTE register rejected error=\(error.localizedDescription) status=\(LaunchAtLogin.statusText)")
        }
        failures += report("login-status-reported", true, LaunchAtLogin.statusText)

        // 恢复原状：测试结束不留登录项
        do {
            try LaunchAtLogin.setEnabled(false)
            print("NOTE unregister ok status=\(LaunchAtLogin.statusText)")
        } catch {
            print("NOTE unregister failed error=\(error.localizedDescription) status=\(LaunchAtLogin.statusText)")
        }
        return failures
    }

    // MARK: - 损坏文件
    private static func runCorruptRealFile() async -> Int {
        var failures = 0
        let fileURL = AppPaths.settingsURL

        // 先保证有一份合法文件（默认值），并记住原始字节
        _ = SettingsStore()
        let originalData = (try? Data(contentsOf: fileURL)) ?? Data()

        try? Data("{ 这不再是 JSON".utf8).write(to: fileURL)
        let recovered = SettingsStore()
        print("NOTE recovered defaults: port=\(recovered.mixedPort) level=\(recovered.logLevel.rawValue)")

        failures += report("corrupt-default-port", recovered.mixedPort == 7890, "port=\(recovered.mixedPort)")
        failures += report("corrupt-default-level", recovered.logLevel == .info)
        failures += report("corrupt-backup-created", recovered.corruptBackupURL != nil)

        if let backup = recovered.corruptBackupURL {
            print("NOTE backup=\(backup.lastPathComponent)")
            failures += report("corrupt-backup-exists", FileManager.default.fileExists(atPath: backup.path))
            failures += report(
                "corrupt-backup-pattern",
                backup.lastPathComponent.hasPrefix("settings.corrupt-")
                    && backup.lastPathComponent.hasSuffix(".json")
            )
        }

        let rewritten = (try? Data(contentsOf: fileURL)).flatMap {
            try? JSONDecoder().decode(SettingsStore.Values.self, from: $0)
        }
        failures += report("corrupt-rewritten-valid", rewritten != nil)

        // 还原用户原始设置，别把测试痕迹留在真实目录
        try? originalData.write(to: fileURL)
        let restored = SettingsStore()
        print("NOTE restored settings: \(restored.values)")
        return failures
    }

    // MARK: - 工具

    private static func latestLogText() -> String {
        let directory = AppPaths.logsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let latest = files.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        guard let latest else { return "" }
        return (try? String(contentsOf: latest, encoding: .utf8)) ?? ""
    }

    /// 同步跑一条命令并收集 stdout+stderr（`lsof` 只在自检里用）
    private static func shell(_ path: String, _ arguments: [String]) async -> String {
        await Task.detached(priority: .userInitiated) { () -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return ""
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
#endif
