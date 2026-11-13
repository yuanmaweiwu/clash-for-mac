#if DEBUG
import Foundation

/// 日志窗口自检（仅 DEBUG）：`CLASH_LOG_HARNESS=1` 时在 UI 起来前跑并退出。
///
/// 用途：命令行验证环形缓冲（500 上限）/ 级别筛选 / 暂停冻结 / 导出 / 脱敏，
/// 不必点菜单栏。日志流本身（`/logs` WS）由面板实测覆盖。
@MainActor
enum LogStoreHarness {

    private static let sampleSecret = "S3CR3T-api-secret"
    private static let subscriptionURL = "https://sub.example.com/api/v1/client/subscribe?token=abc123&key=def456&flag=keep"

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["CLASH_LOG_HARNESS"] != nil else { return }
        let failures = run()
        print(failures == 0 ? "HARNESS DONE failures=0" : "HARNESS DONE failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// 打印一行并折算成失败数（0 / 1），与 `SystemProxyHarness` 同风格
    private static func report(_ name: String, _ passed: Bool, _ detail: String = "") -> Int {
        print(passed ? "PASS \(name)" : "FAIL \(name) \(detail)")
        return passed ? 0 : 1
    }

    private static func run() -> Int {
        var failures = 0

        // 1. 脱敏：secret 与订阅 URL 的 token / key 都打码，其余参数原样保留
        let raw = "[API] auth \(sampleSecret) fetch \(subscriptionURL) ok"
        let redacted = LogRedactor.redact(raw, secret: sampleSecret)
        print("NOTE redacted: \(redacted)")
        failures += report("redact-secret", !redacted.contains(sampleSecret))
        failures += report("redact-token", !redacted.contains("abc123"))
        failures += report("redact-key", !redacted.contains("def456"))
        failures += report("redact-keeps-other-params", redacted.contains("flag=keep"))
        failures += report("redact-marks", redacted.contains("***"))

        let store = LogStore(kernel: KernelService())

        // 2. 环形缓冲：超 500 条丢最旧
        for index in 1...520 {
            store.appendForSelfCheck(level: .info, payload: "line-\(index)", secret: nil)
        }
        failures += report("ring-capacity", store.lines.count == LogStore.capacity, "count=\(store.lines.count)")
        failures += report("ring-drops-oldest", store.visibleLines.first?.payload == "line-21", "first=\(store.visibleLines.first?.payload ?? "nil")")
        failures += report("ring-keeps-newest", store.visibleLines.last?.payload == "line-520")

        // 3. 级别筛选：取消 warning → warning 行消失；恢复 → 回来
        store.appendForSelfCheck(level: .warning, payload: "warn-line", secret: nil)
        store.appendForSelfCheck(level: .error, payload: "error-line", secret: nil)
        let beforeFilter = store.visibleLines.count
        store.toggleLevel(.warning)
        let afterRemove = store.visibleLines.count
        failures += report("filter-hides-warning", afterRemove == beforeFilter - 1, "before=\(beforeFilter) after=\(afterRemove)")
        store.toggleLevel(.warning)
        failures += report("filter-restores-warning", store.visibleLines.count == beforeFilter)

        // 4. 暂停：暂停后显示行数不增（缓冲仍写），继续后补齐
        store.setPaused(true)
        let frozen = store.visibleLines.count
        let bufferedBefore = store.lines.count
        store.appendForSelfCheck(level: .info, payload: "paused-1", secret: nil)
        store.appendForSelfCheck(level: .error, payload: "paused-2", secret: nil)
        let expectedBuffered = min(LogStore.capacity, bufferedBefore + 2)
        failures += report("pause-freezes-view", store.visibleLines.count == frozen, "frozen=\(frozen) now=\(store.visibleLines.count)")
        failures += report("pause-still-buffers", store.lines.count == expectedBuffered, "buffered=\(store.lines.count) expected=\(expectedBuffered)")
        store.setPaused(false)
        failures += report("resume-catches-up", store.visibleLines.count == expectedBuffered, "now=\(store.visibleLines.count)")

        // 5. 导出：落盘内容已脱敏
        let directory = URL.temporaryDirectory.appending(path: "clash-log-harness", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store.appendForSelfCheck(level: .error, payload: "boom \(sampleSecret) \(subscriptionURL)", secret: sampleSecret)

        do {
            let url = try store.export(to: directory)
            let text = try String(contentsOf: url, encoding: .utf8)
            failures += report("export-file", text.contains("[error] boom"), "…\(text.suffix(120))")
            failures += report("export-redacted", !text.contains(sampleSecret) && !text.contains("abc123"))
            print("NOTE exported: \(url.path)")
            if let last = text.split(separator: "\n").last {
                print("NOTE exported-last-line: \(last)")
            }
        } catch {
            failures += report("export-file", false, "\(String(describing: error))")
        }

        // 6. 清空
        store.clear()
        failures += report("clear", store.lines.isEmpty && store.visibleLines.isEmpty)

        return failures
    }
}
#endif
