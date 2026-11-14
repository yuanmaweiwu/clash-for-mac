#if DEBUG
import Foundation

/// 系统代理自检（仅 DEBUG）：`CLASH_PROXY_HARNESS=<mode>` 时在 UI 起来前跑并退出。
///
/// 用途：命令行验证「开启 → 读回 → 还原 → 逐字段一致」，以及崩溃兜底与失败回滚，
/// 不需要点菜单栏。配合 `Scripts/check-system-proxy.sh` 使用。
///
/// 模式：
/// - `roundtrip`：enable(7890) → 校验每服务读回 → disable → 快照删除
/// - `stale`：enable 后新建一个 service（模拟重启）→ `restoreIfNeeded` 兜底还原
/// - `terminate`：enable → `disableSynchronouslyForTermination()`（App 退出路径）
/// - `rollback`：注入「读回校验失败」→ 必须回滚、删快照、lastError 有值
/// - `readonly`：快照目录不可写（`CLASH_PROXY_SNAPSHOT_PATH`）→ 必须整体放弃、系统代理不动
@MainActor
enum SystemProxyHarness {

    private static let testPort = 7890

    static func runIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["CLASH_PROXY_HARNESS"], !mode.isEmpty else { return }
        var failures = 0
        var finished = false
        Task { @MainActor in
            failures = await run(mode: mode)
            finished = true
        }

        let deadline = Date().addingTimeInterval(240)
        while !finished && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        print(finished ? "HARNESS DONE failures=\(failures)" : "HARNESS TIMEOUT")
        exit(finished ? (failures == 0 ? 0 : 1) : 2)
    }

    // MARK: - 断言

    /// 打印一行并折算成失败数（0 / 1），避免把闭包跨隔离层级传递
    private static func report(_ name: String, _ passed: Bool, _ detail: String = "") -> Int {
        print(passed ? "PASS \(name)" : "FAIL \(name) \(detail)")
        return passed ? 0 : 1
    }

    // MARK: - 流程

    private static func run(mode: String) async -> Int {
        let snapshotURL: URL
        if let path = ProcessInfo.processInfo.environment["CLASH_PROXY_SNAPSHOT_PATH"], !path.isEmpty {
            snapshotURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            snapshotURL = AppPaths.systemProxySnapshotURL
        }

        let service = SystemProxyService(snapshotURL: snapshotURL)
        var failures = 0

        // 上次遗留快照先清干净，保证「测试前状态 = 用户原值」
        if service.hasSnapshot {
            do { try await service.disable() } catch {
                print("WARN 清理遗留快照失败：\(String(describing: error))")
            }
        }

        let names = (try? await service.services()) ?? []
        failures += report("services", !names.isEmpty, "\(names.count) 个服务")
        guard !names.isEmpty else { return failures + 1 }

        var before: [(name: String, state: ServiceProxyState)] = []
        for name in names {
            if let state = try? await service.currentState(of: name) {
                before.append((name, state))
            }
        }
        failures += report("capture-before", before.count == names.count)

        switch mode {
        case "roundtrip":
            failures += await runRoundtrip(service: service, names: names)
        case "stale":
            failures += await runStale(service: service, snapshotURL: snapshotURL)
        case "terminate":
            failures += await runTerminate(service: service)
        case "hold":
            failures += await runHold(service: service)
        case "rollback":
            failures += await runRollback(service: service)
        case "readonly":
            failures += await runReadOnly(service: service)
        case "panel":
            failures += await runPanel(hold: false)
        case "panel-hold":
            // 与 panel 相同，但在「代理开」「代理关」两个状态各停 8 秒，
            // 让外部 shell 用 networksetup / pgrep / curl 取证（不点菜单栏）
            failures += await runPanel(hold: true)
        default:
            failures += report("mode", false, "未知模式 \(mode)")
        }

        // 逐字段比对测试前后（web / secure / socks / PAC / bypass 全量）
        for entry in before {
            guard let after = try? await service.currentState(of: entry.name) else {
                failures += report("compare \(entry.name)", false, "读不到当前状态")
                continue
            }
            failures += report("compare \(entry.name)", after == entry.state, "\(after) != \(entry.state)")
        }

        failures += report("snapshot-cleaned", !service.hasSnapshot, "快照仍存在：\(snapshotURL.path)")

        // 最后一道保险：绝不让测试把系统代理留在开着的状态
        if service.hasSnapshot {
            service.disableSynchronouslyForTermination()
        }
        return failures
    }

    private static func runRoundtrip(service: SystemProxyService, names: [String]) async -> Int {
        var failures = 0
        do {
            try await service.enable(port: testPort)
            failures += report("enable", service.isEnabled, "lastError=\(String(describing: service.lastError))")

            for name in names {
                guard let state = try? await service.currentState(of: name) else {
                    failures += report("readback \(name)", false, "读不到状态")
                    continue
                }
                failures += report(
                    "web \(name)",
                    state.web.enabled && state.web.server == "127.0.0.1" && state.web.port == testPort,
                    "\(state.web)"
                )
                failures += report(
                    "secure \(name)",
                    state.secure.enabled && state.secure.server == "127.0.0.1" && state.secure.port == testPort,
                    "\(state.secure)"
                )
                failures += report("pac-off \(name)", !state.auto.enabled, "\(state.auto)")
            }

            try await service.disable()
            failures += report("disable", !service.isEnabled, "lastError=\(String(describing: service.lastError))")
            failures += report("snapshot-removed", !service.hasSnapshot)
        } catch {
            failures += report("roundtrip", false, "\(String(describing: error))")
        }
        return failures
    }

    private static func runStale(service: SystemProxyService, snapshotURL: URL) async -> Int {
        var failures = 0
        do {
            try await service.enable(port: testPort)
            failures += report("enable", service.isEnabled)

            // 模拟「App 崩溃后重启」：新实例从快照读出「我们改过代理」
            let relaunched = SystemProxyService(snapshotURL: snapshotURL)
            failures += report("flag-from-snapshot", relaunched.isEnabled)
            await relaunched.restoreIfNeeded(kernelRunning: false)
            failures += report(
                "restore-if-needed",
                !relaunched.isEnabled && !relaunched.hasSnapshot,
                "lastError=\(String(describing: relaunched.lastError))"
            )
        } catch {
            failures += report("stale", false, "\(String(describing: error))")
        }
        return failures
    }

    /// 开启后停 6 秒再关：让外部 shell 在「代理真的开着」的窗口里跑 `networksetup -get*` 取证
    private static func runHold(service: SystemProxyService) async -> Int {
        var failures = 0
        do {
            try await service.enable(port: testPort)
            failures += report("enable", service.isEnabled)
            try? await Task.sleep(for: .seconds(6))
            try await service.disable()
            failures += report("disable", !service.isEnabled)
            failures += report("snapshot-removed", !service.hasSnapshot)
        } catch {
            failures += report("hold", false, "\(String(describing: error))")
        }
        return failures
    }

    private static func runTerminate(service: SystemProxyService) async -> Int {
        var failures = 0
        do {
            try await service.enable(port: testPort)
            failures += report("enable", service.isEnabled)
            service.disableSynchronouslyForTermination()
            failures += report("terminate-restore", !service.isEnabled && !service.hasSnapshot)
        } catch {
            failures += report("terminate", false, "\(String(describing: error))")
        }
        return failures
    }

    private static func runRollback(service: SystemProxyService) async -> Int {
        var failures = 0
        service.debugFailVerification = true
        do {
            try await service.enable(port: testPort)
            failures += report("rollback", false, "读回校验失败时不应该成功")
        } catch let error as SystemProxyError {
            print("NOTE rollback error: \(error.logDescription)")
            if case .verificationFailed = error {
                failures += report("rollback-error-kind", true)
            } else {
                failures += report("rollback-error-kind", false, "\(error)")
            }
        } catch {
            failures += report("rollback-error-kind", false, "\(String(describing: error))")
        }
        failures += report("rollback-snapshot-removed", !service.hasSnapshot, "回滚成功应删除快照")
        failures += report("rollback-lastError", service.lastError != nil)
        print("NOTE lastError.userMessage=\(service.lastError?.userMessage ?? "nil")")
        return failures
    }

    /// 面板语义（系统代理磁贴 = 总开关）：点一下 → 起内核（若没在跑）+ 接管代理；
    /// 再点一下 → 只还原系统代理，内核继续运行。
    /// `hold = true` 时在两个状态各停 8 秒，供外部取证。
    private static func runPanel(hold: Bool = false) async -> Int {
        var failures = 0
        let kernel = KernelService()
        let systemProxy = SystemProxyService()
        // 自检不让模型自动启内核：初始相位固定为 stopped，方便逐步断言
        let model = PanelPreviewModel(kernel: kernel, systemProxy: systemProxy, autoStartsKernel: false)

        failures += report(
            "initial-off",
            model.connectionState == .off && !model.isSystemProxyOn && model.status == .idle,
            "state=\(model.connectionState) status=\(model.status)"
        )

        model.toggleConnection()
        var waited = 0.0
        while waited < 60, !model.isSystemProxyOn {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 0.2
        }
        failures += report(
            "tile-on",
            model.isSystemProxyOn && model.connectionState == .on,
            "state=\(model.connectionState) error=\(String(describing: model.errorMessage))"
        )
        failures += report("kernel-running", model.phase == .running, "phase=\(model.phase)")
        failures += report("status-proxying", model.status == .proxying, "\(model.status)")

        // `/traffic` WS：内核 running 后应在一个重连周期内拿到采样（状态条出真实速率）
        var trafficWaited = 0.0
        while trafficWaited < 8, !model.showsLiveTraffic {
            try? await Task.sleep(for: .milliseconds(200))
            trafficWaited += 0.2
        }
        failures += report(
            "traffic-live",
            model.showsLiveTraffic,
            "showsLiveTraffic=\(model.showsLiveTraffic) down=\(model.downRateText) up=\(model.upRateText)"
        )

        if hold {
            print("HOLD proxy-on port=\(kernel.port ?? 0) version=\(kernel.kernelVersion ?? "-")")
            await traceTraffic(model: model, seconds: 24)
        }

        model.toggleConnection()
        waited = 0.0
        while waited < 60, model.isSystemProxyOn {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 0.2
        }
        failures += report(
            "tile-off",
            !model.isSystemProxyOn && model.connectionState == .off,
            "state=\(model.connectionState) error=\(String(describing: model.errorMessage))"
        )
        // 关代理不停内核：节点仍然可见可选，状态条回到「已就绪」
        failures += report("kernel-kept", model.phase == .running, "phase=\(model.phase)")
        failures += report("status-ready", model.status == .ready, "\(model.status)")

        if hold {
            print("HOLD proxy-off kernel-phase=\(model.phase)")
            await traceTraffic(model: model, seconds: 12)
        }

        // 清理：代理与内核都不能留在运行态（与 App 退出走同一套同步实现）
        if model.isSystemProxyOn {
            systemProxy.disableSynchronouslyForTermination()
        }
        if kernel.phase != .stopped {
            await kernel.stop()
        }
        return failures
    }

    /// 逐秒打印面板的速率 / 在线状态：供外部 shell 在 `panel-hold` 期间制造流量、挂起内核取证
    private static func traceTraffic(model: PanelPreviewModel, seconds: Int) async {
        for _ in 0..<seconds {
            print(
                "NOTE rate down=\(model.downRateText) up=\(model.upRateText)"
                    + " streaming=\(model.showsLiveTraffic) curve=\(model.hasTrafficCurve)"
            )
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func runReadOnly(service: SystemProxyService) async -> Int {
        var failures = 0
        do {
            try await service.enable(port: testPort)
            failures += report("readonly", false, "快照写不进去时不应该修改系统代理")
        } catch let error as SystemProxyError {
            print("NOTE readonly error: \(error.logDescription)")
            if case .snapshotWriteFailed = error {
                failures += report("readonly-snapshot-write-failed", true)
            } else {
                failures += report("readonly-snapshot-write-failed", false, "\(error)")
            }
        } catch {
            failures += report("readonly-snapshot-write-failed", false, "\(String(describing: error))")
        }
        failures += report("readonly-no-proxy", !service.isEnabled)
        failures += report("readonly-no-snapshot", !service.hasSnapshot)
        return failures
    }
}

#endif
