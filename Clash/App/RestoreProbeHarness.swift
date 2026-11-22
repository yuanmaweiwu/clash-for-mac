import Foundation

#if DEBUG
/// 真机自检夹具（`CLASH_RESTORE_PROBE=/tmp/restore-probe.json`）：
/// 每 500ms 把当前内核 `/proxies` 里每个策略组的 `type` / `now` 写进指定文件，
/// 用来验证「开机恢复节点选择」在本地内核与 TUN 内核上都生效。
///
/// 只导出组名 / 类型 / 选中项，**不读也不写 API secret**；未设置环境变量时完全不启动。
@MainActor
enum RestoreProbeHarness {

    static func runIfRequested(kernel: KernelService) {
        guard let path = ProcessInfo.processInfo.environment["CLASH_RESTORE_PROBE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        Task {
            // 覆盖内核启动 → TUN 接管 → 恢复完成这整段窗口
            for _ in 0 ..< 80 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let port = kernel.port, let secret = kernel.secret else { continue }
                let client = ClashAPIClient(port: port, secret: secret, timeout: 2)
                guard let proxies = try? await client.proxies() else { continue }

                var groups: [String: [String: String]] = [:]
                for (name, entry) in proxies where entry.isGroup {
                    groups[name] = ["type": entry.type ?? "", "now": entry.now ?? ""]
                }
                let payload: [String: Any] = [
                    "phase": "\(kernel.phase)",
                    "external": kernel.isExternal,
                    "groups": groups,
                ]
                guard let data = try? JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .sortedKeys]
                ) else { continue }
                try? data.write(to: url)
            }
        }
    }
}
#endif
