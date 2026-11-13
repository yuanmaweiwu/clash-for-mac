#if DEBUG
import Foundation

/// 真机 TUN 自检（仅 DEBUG）：`CLASH_TUN_SMOKE=1`（默认）/ `=probe` / `=badconfig`。
///
/// 这一轮**会真的启动 root 内核**（用户已在真机授权安装），所以：
/// - 用 App 自己的 `TunService` 实例（XPC 校验要求客户端是本 App 的可执行路径）
/// - 结束前一定 `disable()`，把 root 内核停掉
/// - 不碰 `HelperInstaller.install()`（组件已装，不能重复弹密码框）
///
/// 输出直接打到 stdout，供真机验收贴回。
@MainActor
enum TunSmokeHarness {

    static func requestedMode() -> String? {
        ProcessInfo.processInfo.environment["CLASH_TUN_SMOKE"]
    }

    static func startIfRequested(
        mode: String,
        systemProxy: SystemProxyService,
        kernel: KernelService,
        tun: TunService,
        model: PanelPreviewModel
    ) {
        Task { @MainActor in
            let failures: Int
            switch mode {
            case "probe":
                failures = await probe()
            case "badconfig":
                failures = await badConfig()
            case "dump":
                failures = dumpConfig()
            case "reopen":
                failures = await reopenCycle(model: model, tun: tun)
            case "resub":
                failures = await resubscribeCycle(model: model, tun: tun)
            case "helper":
                failures = await helperStates(tun: tun)
            default:
                failures = await fullCycle(tun: tun, kernel: kernel, systemProxy: systemProxy)
            }
            // 自检用 exit() 收场，绕过了 AppTerminationGuard：先把自己拉起来的本地内核停掉，
            // 否则会在机器上留一个占着 7890 的孤儿进程
            if kernel.phase == .running || kernel.isTransitioning {
                await kernel.stop()
            }
            print(failures == 0 ? "SMOKE DONE failures=0" : "SMOKE DONE failures=\(failures)")
            exit(failures == 0 ? 0 : 1)
        }
    }

    // MARK: - 模式

    private static func probe() async -> Int {
        do {
            let snapshot = try await HelperClient.shared.probe()
            print("PROBE wire=\(snapshot.wireValue)")
            print("PROBE missing=\(snapshot.missingComponents)")
            return 0
        } catch {
            print("FAIL probe \(error)")
            return 1
        }
    }

    /// 把「本轮真机要送给 helper 的那份 TUN 配置」写到磁盘，供本地 `mihomo -t` / 手工复现。
    /// 路径由 `CLASH_TUN_DUMP` 指定（含 secret，用完即删）。
    private static func dumpConfig() -> Int {
        guard let path = ProcessInfo.processInfo.environment["CLASH_TUN_DUMP"] else {
            print("FAIL dump 需要 CLASH_TUN_DUMP=<path>")
            return 1
        }
        guard let profile = ProfileLocator.locate() else {
            print("FAIL dump 没有可用订阅")
            return 1
        }
        do {
            let ports = try PortAllocator.allocateDistinct(2)
            let yaml = try RuntimeConfigBuilder.yaml(
                from: profile,
                injected: .init(
                    mixedPort: KernelService().settings.mixedPort,
                    controllerPort: ports[0],
                    dnsPort: ports[1],
                    secret: RuntimeConfigBuilder.makeSecret(),
                    tunEnabled: true,
                    tunStack: .gvisor
                )
            )
            try Data(yaml.utf8).write(to: URL(fileURLWithPath: path))
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            print("DUMP ok \(path) bytes=\(yaml.utf8.count) profile=\(ProfileLocator.displayName(for: profile))")
            return 0
        } catch {
            print("FAIL dump \(error.localizedDescription)")
            return 1
        }
    }

    /// 非法 YAML：helper 必须拒绝并给中文原因，且不覆盖已有运行配置
    private static func badConfig() async -> Int {
        var failures = 0
        do {
            try await HelperClient.shared.applyRuntimeConfig(Data("tun: [this is not a mapping".utf8))
            print("FAIL badconfig 非法正文被接受")
            failures += 1
        } catch {
            print("OK badconfig 被拒绝：\(describe(error))")
        }

        do {
            try await HelperClient.shared.applyRuntimeConfig(Data())
            print("FAIL badconfig 空正文被接受")
            failures += 1
        } catch {
            print("OK badconfig 空正文被拒绝：\(describe(error))")
        }

        // 拒绝之后进程仍然可用 → 连接没被打断
        do {
            let snapshot = try await HelperClient.shared.probe()
            print("OK badconfig 之后仍可 ping：\(snapshot.wireValue)")
        } catch {
            print("FAIL badconfig 之后 ping 失败：\(describe(error))")
            failures += 1
        }
        return failures
    }

    private static func fullCycle(tun: TunService, kernel: KernelService, systemProxy: SystemProxyService) async -> Int {
        var failures = 0

        print("=== BEFORE ===")
        dumpNetworkState()
        print("helper installed=\(HelperInstaller.isInstalled) proxy=\(systemProxy.isEnabled) mixedPort=\(kernel.settings.mixedPort)")

        do {
            let snapshot = try await HelperClient.shared.probe()
            print("PROBE wire=\(snapshot.wireValue) missing=\(snapshot.missingComponents)")
        } catch {
            print("WARN probe 失败（旧 helper 只会回纯版本号，正常）：\(describe(error))")
        }

        print("=== ENABLE ===")
        await tun.enable()
        let ready = await waitUntilSettled(tun: tun)
        print("phase=\(tun.phase) banner=\(tun.bannerMessage ?? "—")")
        let blockedByGeodata = tun.bannerMessage?.contains("内核缺少") == true
        if !ready, blockedByGeodata {
            print("SKIP 运行目录缺 geodata（组件安装时未拷贝）；其余流程未触达")
        } else if !ready {
            print("FAIL enable 未进入 on")
            failures += 1
        }

        print("=== ON ===")
        dumpNetworkState()

        // 给 utun / 路由 / DNS 一点稳定时间
        try? await Task.sleep(for: .seconds(2))
        dumpNetworkState()

        // 闸门检查：失败之后磁贴必须还能再点（不能留 isBusy / isInstalling 闩锁）
        if !ready {
            print("GATE busy=\(tun.isBusy) installing=\(tun.isInstalling) tile=\(tun.tileState.rawValue)")
            if tun.isBusy || tun.isInstalling {
                print("FAIL 失败后仍有忙碌闩锁")
                failures += 1
            }
        }

        print("=== DISABLE ===")
        if ready {
            await tun.disable(restartLocalKernel: false)
            let stopped = await waitUntilOff(tun: tun)
            print("phase=\(tun.phase) banner=\(tun.bannerMessage ?? "—")")
            if !stopped {
                print("FAIL disable 未回到 off")
                failures += 1
            }
        } else {
            print("skip disable（ENABLE 未成功，无可停内核）")
        }

        try? await Task.sleep(for: .seconds(1))
        print("=== AFTER ===")
        dumpNetworkState()

        do {
            let state = try await HelperClient.shared.kernelState()
            print("kernelState=\(state ?? "nil")")
            if state != nil {
                print("FAIL root 内核仍在运行")
                failures += 1
            }
        } catch {
            print("WARN kernelState 失败：\(describe(error))")
        }

        if systemProxy.hasSnapshot {
            print("FAIL 系统代理快照仍在")
            failures += 1
        }
        return failures
    }

    /// 「TUN 开着 → 改配置 → 自动重开」的真机验证：走面板模型的真实入口
    private static func reopenCycle(model: PanelPreviewModel, tun: TunService) async -> Int {
        var failures = 0

        print("=== ENABLE ===")
        await tun.enable()
        guard await waitUntilSettled(tun: tun) else {
            print("SKIP reopen 前置 enable 未成功：\(tun.bannerMessage ?? "—")")
            return 0
        }
        dumpNetworkState()

        print("=== CONFIG CHANGE (restartKernelForSettings) ===")
        model.restartKernelForSettings()
        let leftOn = await waitUntilLeavesOn(tun: tun)
        let backOn = await waitUntilSettled(tun: tun)
        print("leftOn=\(leftOn) backOn=\(backOn) phase=\(tun.phase) banner=\(tun.bannerMessage ?? "—")")
        if !leftOn || !backOn {
            print("FAIL 自动重开未完成")
            failures += 1
        }
        dumpNetworkState()

        await tun.disable(restartLocalKernel: false)
        _ = await waitUntilOff(tun: tun)
        return failures
    }

    /// 订阅更新触发「关 → 换配置 → 重开」：走 `refreshProfile()` 的真实路径
    private static func resubscribeCycle(model: PanelPreviewModel, tun: TunService) async -> Int {
        var failures = 0

        print("=== ENABLE ===")
        await tun.enable()
        guard await waitUntilSettled(tun: tun) else {
            print("SKIP resub 前置 enable 未成功：\(tun.bannerMessage ?? "—")")
            return 0
        }
        dumpNetworkState()

        print("=== REFRESH SUBSCRIPTION ===")
        let updatedBefore = model.activeSubscription?.updatedAt
        model.refreshProfile()
        for _ in 0..<240 where model.updatingProfileID != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let updated = model.activeSubscription?.updatedAt != updatedBefore
        print("subscription updated=\(updated) phase=\(tun.phase) banner=\(tun.bannerMessage ?? "—")")

        if updated {
            let leftOn = await waitUntilLeavesOn(tun: tun)
            let backOn = await waitUntilSettled(tun: tun)
            print("leftOn=\(leftOn) backOn=\(backOn) phase=\(tun.phase)")
            if !leftOn || !backOn {
                print("FAIL 订阅更新后未自动重开")
                failures += 1
            }
        } else {
            // 更新失败：按要求不重开，TUN 保持原状（旧配置仍有效）
            print("INFO 订阅更新失败 → 不重开；phase=\(tun.phase)")
            if tun.phase != .on {
                print("FAIL 更新失败时 TUN 不该被关闭")
                failures += 1
            }
        }
        dumpNetworkState()

        await tun.disable(restartLocalKernel: false)
        _ = await waitUntilOff(tun: tun)
        return failures
    }

    /// 组件状态机文案（真实状态 + 三种夹具状态）
    private static func helperStates(tun: TunService) async -> Int {
        let model = HelperComponentModel(tun: tun)
        await model.refresh()
        print("REAL state=\(model.state) status=\(model.statusText) action=\(model.action?.title ?? "nil")")

        let fixtures: [(String, HelperComponentModel.State)] = [
            ("未安装", .notInstalled),
            ("已安装", .installed(version: HelperVersion)),
            ("需要更新", .needsUpdate(installedVersion: 2, legacyPayload: true)),
            ("已装未运行", .installedNotRunning)
        ]
        for (label, state) in fixtures {
            model.applyPreviewState(state)
            print("FIXTURE [\(label)] status=\(model.statusText) | hint=\(model.hintText) | action=\(model.action?.title ?? "nil")")
        }
        return 0
    }

    // MARK: - 等待

    private static func waitUntilSettled(tun: TunService) async -> Bool {
        for _ in 0..<120 {
            switch tun.phase {
            case .on: return true
            case .failed, .off, .needsInstall, .awaitingAuthorization: return false
            case .starting, .stopping: try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return false
    }

    /// 等它离开 on（重开的第一步是关闭）
    private static func waitUntilLeavesOn(tun: TunService) async -> Bool {
        for _ in 0..<80 {
            if tun.phase != .on { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func waitUntilOff(tun: TunService) async -> Bool {
        for _ in 0..<40 {
            if case .off = tun.phase { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    // MARK: - 取证

    private static func dumpNetworkState() {
        if let route = SystemNetworkProbe.runCommand("/sbin/route", ["-n", "get", "default"]) {
            let interface = route.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("interface:") } ?? "interface: ?"
            let gateway = route.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("gateway:") } ?? "gateway: ?"
            print("route default → \(interface) / \(gateway)")
        } else {
            print("route default → （无默认路由）")
        }

        print("utun(in a.addr) → \(activeTunnels().joined(separator: ", "))")

        if let ps = SystemNetworkProbe.runCommand("/bin/ps", ["-axo", "user,pid,command"]) {
            let kernels = ps.split(separator: "\n")
                .map(String.init)
                .filter { $0.contains("PrivilegedHelperTools/mihomo") }
            print("root mihomo → \(kernels.isEmpty ? "无" : kernels.joined(separator: " | "))")
        }

        if let table = SystemNetworkProbe.runCommand("/usr/sbin/netstat", ["-rn", "-f", "inet"]) {
            let interesting = table.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in
                    line.hasPrefix("0/1") || line.hasPrefix("128.0/1") || line.hasPrefix("default")
                }
            print("routes(0/1,128/1,default) → \(interesting.isEmpty ? "无" : interesting.joined(separator: " | "))")
        }

        if let resolv = SystemNetworkProbe.runCommand("/usr/sbin/scutil", ["--dns"]) {
            let servers = resolv.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("nameserver[") }
            print("dns → \(servers.prefix(4).joined(separator: "; "))")
        }
    }

    private static func activeTunnels() -> [String] {
        guard let output = SystemNetworkProbe.runCommand("/sbin/ifconfig", ["-a"]) else { return [] }
        var current: String?
        var result: [String] = []
        for line in output.split(separator: "\n") {
            let text = String(line)
            if !text.hasPrefix("\t") && !text.hasPrefix(" ") {
                let name = text.split(separator: ":").first.map(String.init) ?? ""
                current = name.hasPrefix("utun") ? name : nil
                continue
            }
            guard let current else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet ") else { continue }
            let address = String(trimmed.dropFirst(5)).split(separator: " ").first.map(String.init) ?? "?"
            if !result.contains(where: { $0.hasPrefix(current + " ") }) {
                result.append("\(current)=\(address)")
            }
        }
        return result
    }

    private static func describe(_ error: Error) -> String {
        if let helper = error as? HelperClientError { return "\(helper) / \(helper.userMessage)" }
        return error.localizedDescription
    }
}
#endif
