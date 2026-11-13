#if DEBUG
import Foundation

/// 设置的自检（仅 DEBUG）：`CLASH_SETTINGS_HARNESS=1` 时在 UI 起来前跑并退出。
///
/// 覆盖：默认值落盘 / 原子写权限 / 往返读写 / 损坏文件备份与回默认 / 非法端口归一 / UA 生效值。
@MainActor
enum SettingsHarness {

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["CLASH_SETTINGS_HARNESS"] != nil else { return }
        var failures = 0
        failures += run()
        print(failures == 0 ? "HARNESS DONE failures=0" : "HARNESS DONE failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func report(_ name: String, _ passed: Bool, _ detail: String = "") -> Int {
        print(passed ? "PASS \(name)" : "FAIL \(name) \(detail)")
        return passed ? 0 : 1
    }

    private static func run() -> Int {
        var failures = 0
        let directory = URL.temporaryDirectory
            .appending(path: "clash-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "settings.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        print("NOTE file=\(fileURL.path)")

        // 1. 首次启动：默认值 + 落盘 + 0600
        let store = SettingsStore(fileURL: fileURL)
        failures += report("defaults-port", store.mixedPort == 7890, "port=\(store.mixedPort)")
        failures += report("defaults-keep-kernel", store.keepKernelOnProxyOff)
        failures += report("defaults-log-level", store.logLevel == .info)
        failures += report("file-created", FileManager.default.fileExists(atPath: fileURL.path))
        failures += report("file-permissions", permissions(of: fileURL) == 0o600, "mode=\(permissions(of: fileURL) ?? -1)")

        // 2. 往返：改端口 / 日志级别 / 局域网 / UA → 新实例读回同样的值
        store.mixedPort = 17890
        store.logLevel = .debug
        store.allowLAN = true
        store.subscriptionUserAgent = SubscriptionUserAgent.presets[0]
        store.keepKernelOnProxyOff = false
        store.autoUpdateHours = 6
        // 文本字段是 300ms 合并写：自检里立即落盘再重新读
        store.flushPendingWrite()

        let json = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        failures += report("json-has-port", json.contains("17890"), json)
        failures += report("json-has-level", json.contains("debug"))

        let reloaded = SettingsStore(fileURL: fileURL)
        failures += report("roundtrip-port", reloaded.mixedPort == 17890, "port=\(reloaded.mixedPort)")
        failures += report("roundtrip-level", reloaded.logLevel == .debug)
        failures += report("roundtrip-lan", reloaded.allowLAN)
        failures += report("roundtrip-keep-kernel", !reloaded.keepKernelOnProxyOff)
        failures += report("roundtrip-auto-update", reloaded.autoUpdateHours == 6)
        failures += report(
            "roundtrip-ua",
            reloaded.subscriptionUserAgent == SubscriptionUserAgent.presets[0],
            reloaded.subscriptionUserAgent
        )

        // 3. UA 生效值：空 → 默认 mihomo/<版本>；预设 → 预设原值
        reloaded.subscriptionUserAgent = ""
        failures += report(
            "ua-default",
            reloaded.effectiveSubscriptionUserAgent == SubscriptionUserAgent.defaultUserAgent,
            reloaded.effectiveSubscriptionUserAgent
        )
        reloaded.subscriptionUserAgent = "custom-ua/1.0"
        failures += report("ua-custom", reloaded.effectiveSubscriptionUserAgent == "custom-ua/1.0")

        // 4. 损坏文件：备份为 settings.corrupt-*.json，回默认值并重写成合法 JSON
        try? Data("{ this is not json".utf8).write(to: fileURL)
        let recovered = SettingsStore(fileURL: fileURL)
        failures += report("corrupt-backup", recovered.corruptBackupURL != nil, "backup=nil")
        failures += report("corrupt-default-port", recovered.mixedPort == 7890, "port=\(recovered.mixedPort)")
        failures += report("corrupt-default-level", recovered.logLevel == .info)

        let recoveredJSON = (try? Data(contentsOf: fileURL)).flatMap {
            try? JSONDecoder().decode(SettingsStore.Values.self, from: $0)
        }
        failures += report("corrupt-rewritten", recoveredJSON != nil)

        if let backup = recovered.corruptBackupURL {
            failures += report("corrupt-backup-exists", FileManager.default.fileExists(atPath: backup.path))
            failures += report("corrupt-backup-name", backup.lastPathComponent.hasPrefix("settings.corrupt-"))
        }

        // 5. 非法值：端口 22 / 更新间隔 7 → 归一到默认，不阻塞启动
        let badValues = """
        {"mixedPort": 22, "allowLAN": false, "keepKernelOnProxyOff": true,
         "subscriptionUserAgent": "", "autoUpdateHours": 7, "logLevel": "info", "launchAtLogin": false}
        """
        try? Data(badValues.utf8).write(to: fileURL)
        let normalized = SettingsStore(fileURL: fileURL)
        failures += report("normalize-port", normalized.mixedPort == 7890, "port=\(normalized.mixedPort)")
        failures += report("normalize-auto-update", normalized.autoUpdateHours == 0, "hours=\(normalized.autoUpdateHours)")

        // 6. 文本合并写：连续改 UA 20 次只应落盘 1 次（下拉 / 开关仍立即写）
        let debounceURL = URL.temporaryDirectory
            .appending(path: "clash-settings-debounce-\(UUID().uuidString).json")
        let debounced = SettingsStore(fileURL: debounceURL)
        let baseline = debounced.debugPersistCount
        for length in 1...20 {
            debounced.subscriptionUserAgent = String(repeating: "x", count: length)
        }
        let immediate = debounced.debugPersistCount
        debounced.flushPendingWrite()
        let flushed = debounced.debugPersistCount
        failures += report("text-merge-no-write-per-key", immediate == baseline, "baseline=\(baseline) immediate=\(immediate)")
        failures += report("text-merge-one-write", flushed == baseline + 1, "baseline=\(baseline) flushed=\(flushed)")
        try? FileManager.default.removeItem(at: debounceURL)

        // 7. 登录项真实状态（只报告，不在这里改系统设置）
        print("NOTE login-item status=\(LaunchAtLogin.statusText)")

        return failures
    }

    private static func permissions(of url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}
#endif
