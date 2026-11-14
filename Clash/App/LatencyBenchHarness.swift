#if DEBUG
import Foundation

/// 开关耗时基准（仅 DEBUG）：`CLASH_LATENCY_BENCH=<mode>` 时在 UI 起来前跑完并退出。
///
/// 模式：
/// - `proxy`：系统代理开 / 关各 3 次，打印 capture / set / verify / total（毫秒，取中位数）
/// - `tun`：TUN 开 / 关各 3 次，打印 conflict / closeProxy / stopLocalKernel / buildYaml /
///   applyConfig / spawn / ready / total（需要 helper 已安装，否则 SKIP）
/// - `helper`：组件安装脚本的非交互部分（真正的安装会弹密码，不自动跑）
/// - `all` / `1`：以上全部
///
/// 系统代理基准用**临时快照路径**（`/tmp/…`），不往真实数据根写任何东西；
/// TUN / 组件基准只读用户目录，不清也不写订阅数据。
@MainActor
enum LatencyBenchHarness {

    static var isRequested: Bool {
        guard let mode = ProcessInfo.processInfo.environment["CLASH_LATENCY_BENCH"] else { return false }
        return !mode.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func runIfRequested(
        kernel: KernelService,
        tun: TunService,
        settings: SettingsStore
    ) {
        guard let raw = ProcessInfo.processInfo.environment["CLASH_LATENCY_BENCH"] else { return }
        let mode = raw.trimmingCharacters(in: .whitespaces).lowercased()
        Task { @MainActor in
            var failures = 0
            if mode == "all" || mode == "1" {
                failures += await runProxy(port: settings.mixedPort)
                failures += await runTun(tun: tun, kernel: kernel)
                failures += runHelperScript()
            } else if mode == "proxy" {
                failures += await runProxy(port: settings.mixedPort)
            } else if mode == "tun" {
                failures += await runTun(tun: tun, kernel: kernel)
            } else if mode == "tun-parts" {
                failures += await runTunParts(settings: settings)
            } else if mode == "helper" {
                failures += runHelperScript()
            } else {
                print("BENCH FAIL 未知模式 \(mode)（proxy / tun / helper / all）")
                failures += 1
            }
            print("BENCH DONE failures=\(failures)")
            exit(failures == 0 ? 0 : 1)
        }
    }

    // MARK: - 系统代理

    private static func runProxy(port: Int) async -> Int {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appending(path: "clash-bench-snapshot-\(UUID().uuidString).json")
        let service = SystemProxyService(snapshotURL: snapshotURL)
        var failures = 0

        if service.hasSnapshot {
            try? await service.disable()
        }
        defer {
            if service.hasSnapshot { service.disableSynchronouslyForTermination() }
            try? FileManager.default.removeItem(at: snapshotURL)
        }

        var onRounds: [[String: Double]] = []
        var offRounds: [[String: Double]] = []
        for round in 1...3 {
            do {
                LatencyTrace.shared.reset()
                let wall = ContinuousClock.now
                try await service.enable(port: port)
                let onWall = ContinuousClock.now - wall
                let on = stages(["capture", "set", "verify", "total"])
                onRounds.append(on)
                print("BENCH proxy on round=\(round) \(line(on)) wall=\(ms(onWall))")

                LatencyTrace.shared.reset()
                let offBegan = ContinuousClock.now
                try await service.disable()
                let offWall = ContinuousClock.now - offBegan
                let off = stages(["capture", "set", "verify", "total"])
                offRounds.append(off)
                print("BENCH proxy off round=\(round) \(line(off)) wall=\(ms(offWall))")
            } catch {
                print("BENCH FAIL proxy round=\(round)：\(String(describing: error))")
                failures += 1
                break
            }
        }
        if !onRounds.isEmpty {
            print("BENCH MEDIAN proxy on \(line(median(onRounds)))")
        }
        if !offRounds.isEmpty {
            print("BENCH MEDIAN proxy off \(line(median(offRounds)))")
        }
        // 兜底：绝不让基准把系统代理留在开着
        if service.hasSnapshot { service.disableSynchronouslyForTermination() }
        return failures
    }

    /// 取本轮的阶段取样（缺的记 0，便于对齐输出）
    private static func stages(_ names: [String]) -> [String: Double] {
        let snapshot = LatencyTrace.shared.snapshot()
        var result: [String: Double] = [:]
        for name in names {
            result[name] = snapshot[name]?.last ?? 0
        }
        return result
    }

    private static func line(_ values: [String: Double]) -> String {
        values.keys.sorted()
            .map { "\($0)=\(String(format: "%.1f", values[$0] ?? 0))" }
            .joined(separator: " ")
    }

    private static func median(_ rounds: [[String: Double]]) -> [String: Double] {
        guard !rounds.isEmpty else { return [:] }
        var result: [String: Double] = [:]
        for key in rounds[0].keys {
            let values = rounds.compactMap { $0[key] }.sorted()
            guard !values.isEmpty else { continue }
            result[key] = values[values.count / 2]
        }
        return result
    }

    // MARK: - TUN

    private static func runTun(tun: TunService, kernel: KernelService) async -> Int {
        guard HelperInstaller.isInstalled else {
            print("SKIP BENCH tun 管理员组件未安装（会弹密码，基准不自动装）")
            return 0
        }
        guard !kernel.isTransitioning else {
            print("SKIP BENCH tun 本地内核正在过渡")
            return 0
        }
        if kernel.phase != .stopped { await kernel.stop() }

        var failures = 0
        var onRounds: [[String: Double]] = []
        var offRounds: [[String: Double]] = []

        for round in 1...3 {
            LatencyTrace.shared.reset()
            let wall = ContinuousClock.now
            await tun.enable()
            let onWall = ContinuousClock.now - wall
            guard await waitUntilOn(tun: tun) else {
                print("SKIP BENCH tun round=\(round) 未开启：\(tun.bannerMessage ?? "—")")
                break
            }
            let on = stages([
                "conflict", "closeProxy", "stopLocalKernel", "buildYaml",
                "applyConfig", "spawn", "ready", "total"
            ])
            onRounds.append(on)
            print("BENCH tun on round=\(round) \(line(on)) wall=\(ms(onWall))")

            LatencyTrace.shared.reset()
            let offBegan = ContinuousClock.now
            await tun.disable(restartLocalKernel: false)
            let offWall = ContinuousClock.now - offBegan
            guard tun.phase == .off else {
                print("BENCH FAIL tun round=\(round) 未关闭：\(tun.bannerMessage ?? "—")")
                failures += 1
                break
            }
            let off = stages(["stopKernel", "verify", "total"])
            offRounds.append(off)
            print("BENCH tun off round=\(round) \(line(off)) wall=\(ms(offWall))")
        }

        if !onRounds.isEmpty { print("BENCH MEDIAN tun on \(line(median(onRounds)))") }
        if !offRounds.isEmpty { print("BENCH MEDIAN tun off \(line(median(offRounds)))") }

        // 收尾：TUN 关、root 内核停
        if tun.isOn || tun.isHelperKernelRunning {
            await tun.disable(restartLocalKernel: false)
        }
        if let pid = (try? await HelperClient.shared.kernelState()) ?? nil, !pid.isEmpty {
            try? await HelperClient.shared.stopKernel()
        }
        return failures
    }

    private static func waitUntilOn(tun: TunService) async -> Bool {
        for _ in 0..<160 {
            if tun.isOn { return true }
            if case .failed = tun.phase { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    // MARK: - TUN 分阶段（不需要 helper 的部分）

    /// TUN 开不起来（helper 缺 geodata）时，至少把「冲突检测 + 基线采集 + 生成配置」测准：
    /// 这三段是每次开 TUN 都要跑的固定开销，且不依赖 root helper。
    private static func runTunParts(settings: SettingsStore) async -> Int {
        let profile = ProfileLocator.locate()
        var serial: [Double] = []
        var concurrent: [Double] = []
        var conflict: [Double] = []
        var baseline: [Double] = []
        var build: [Double] = []

        for _ in 0..<3 {
            // 优化前：冲突检测（内部自己抓一次基线）→ 再抓一次基线，串行
            var began = ContinuousClock.now
            _ = await TunConflictDetector.detect()
            let conflictMs = msValue(ContinuousClock.now - began)
            began = ContinuousClock.now
            _ = await SystemNetworkProbe.capture()
            let baselineMs = msValue(ContinuousClock.now - began)
            conflict.append(conflictMs)
            baseline.append(baselineMs)
            serial.append(conflictMs + baselineMs)

            // 优化后：基线并发开始抓，冲突检测复用同一份（不再重复跑 route / netstat）
            began = ContinuousClock.now
            let baselineTask = Task { await SystemNetworkProbe.capture() }
            _ = await TunConflictDetector.detect(baseline: { await baselineTask.value })
            let baselineValue = await baselineTask.value
            concurrent.append(msValue(ContinuousClock.now - began))

            let injected = RuntimeConfigBuilder.Injected(
                mixedPort: settings.mixedPort,
                allowLAN: false,
                controllerPort: 19090,
                dnsPort: 15353,
                secret: "bench-secret",
                logLevel: "info",
                mode: .rule,
                tunEnabled: true,
                tunStack: .gvisor
            )
            began = ContinuousClock.now
            _ = try? await RuntimeConfigBuilder.yaml(from: profile, injected: injected)
            build.append(msValue(ContinuousClock.now - began))
            _ = baselineValue
        }

        print("BENCH tun-parts conflict=\(median(conflict)) baseline=\(median(baseline))"
            + " serial=\(median(serial)) concurrent=\(median(concurrent)) buildYaml=\(median(build))")
        return 0
    }

    private static func median(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "0.0" }
        return String(format: "%.1f", values.sorted()[values.count / 2])
    }

    // MARK: - 组件安装脚本

    /// 只测不弹密码的部分：脚本生成 / 前置检查，以及脚本里的**非交互步骤**
    /// （把内核与 geodata 拷到临时目录、`cmp` 跳过判断、plist 语法检查）。
    /// 真正的 `osascript … with administrator privileges`（用户在密码框输密码那段）**不自动跑**。
    private static func runHelperScript() -> Int {
        let began = ContinuousClock.now
        let script = HelperInstaller.installScript()
        let generated = ContinuousClock.now - began

        let installedStart = ContinuousClock.now
        let installed = HelperInstaller.isInstalled
        let check = ContinuousClock.now - installedStart

        // 非交互步骤模拟（目标目录换成临时目录；命令与脚本里一致）
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory.appending(path: "clash-helper-bench-\(UUID().uuidString)")
        try? fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let kernelSource = AppPaths.kernelBinaryURL
        let kernelCopy = sandbox.appending(path: "mihomo")
        let copyStart = ContinuousClock.now
        _ = SystemNetworkProbe.runCommandSynchronously("/bin/cp", ["-f", kernelSource.path, kernelCopy.path])
        let copy = ContinuousClock.now - copyStart

        let cmpStart = ContinuousClock.now
        _ = SystemNetworkProbe.runCommandSynchronously("/bin/cmp", ["-s", kernelSource.path, kernelCopy.path])
        let cmp = ContinuousClock.now - cmpStart

        var geodataCopy = Duration.zero
        for name in ["geoip.metadb", "geosite.dat"] {
            let source = AppPaths.kernelDirectory.appending(path: name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let start = ContinuousClock.now
            _ = SystemNetworkProbe.runCommandSynchronously(
                "/bin/cp", ["-f", source.path, sandbox.appending(path: name).path]
            )
            geodataCopy += ContinuousClock.now - start
        }

        let plistURL = sandbox.appending(path: "com.clash.helper.plist")
        try? Data(HelperInstaller.launchDaemonPlist.utf8).write(to: plistURL)
        let lintStart = ContinuousClock.now
        _ = SystemNetworkProbe.runCommandSynchronously("/usr/bin/plutil", ["-lint", plistURL.path])
        let lint = ContinuousClock.now - lintStart

        // 语法检查：脚本是拼出来的，括号 / 引号错了只会在输完密码后才炸
        let scriptURL = sandbox.appending(path: "install.sh")
        try? Data(script.utf8).write(to: scriptURL)
        let syntax = SystemNetworkProbe.runCommandSynchronously("/bin/sh", ["-n", scriptURL.path]) ?? ""
        let syntaxOK = syntax.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        print("BENCH helper scriptGen=\(ms(generated)) isInstalledCheck=\(ms(check)) installed=\(installed)"
            + " copyKernel=\(ms(copy)) geodataCopy=\(ms(geodataCopy)) cmpKernel=\(ms(cmp)) plistLint=\(ms(lint))"
            + " script=\(script.utf8.count)B syntax=\(syntaxOK ? "ok" : "FAIL(\(syntax))")")
        print("BENCH helper exec / uninstall 需要密码，未测（脚本非交互部分见上）")
        return syntaxOK ? 0 : 1
    }

    // MARK: - 格式化

    private static func msValue(_ duration: Duration) -> Double {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        return seconds * 1000
    }

    private static func ms(_ duration: Duration) -> String {
        String(format: "%.1f", msValue(duration))
    }
}
#endif
