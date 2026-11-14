#if DEBUG
import Foundation

/// 审核批次 1（`docs/AUDIT-2026-11-14.md`）的真机自检夹具，仅 DEBUG。
///
/// - `CLASH_AUDIT_A2=1`：把 `KernelService.isTransitioning` 置真，直接调用
///   `performFullCleanup` / `installKernelIfMissing` / `updateKernel`，断言三者都被守卫拦住，
///   且**没有删任何目录**（`~/Library/Application Support/Clash` 仍在、mtime 未变）。
///   绝不真点「彻底清理」。
/// - `CLASH_AUDIT_A3=1`：开 TUN → 打印 `A3 READY pid=…` → 等外部 `kill -9` root mihomo，
///   验证 30s 心跳把面板落到「启用失败」；再开一次 → 打印 `A3 PANEL_READY` → 3s 后调
///   `verifyLiveness()`（等价于打开面板），验证 ≤2s 纠正。
///
/// 输出直接打 stdout，供真机验收贴回。
@MainActor
enum AuditBatch1Harness {

    /// 任一批次 1 夹具被请求（`AppEnvironment` 据此不自动起本地内核，保持初始相位干净）
    static var isRequested: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CLASH_AUDIT_A1"] == "1"
            || environment["CLASH_AUDIT_A2"] == "1"
            || environment["CLASH_AUDIT_A3"] == "1"
            || environment["CLASH_AUDIT_A4"] == "1"
            || environment["CLASH_AUDIT_A8"] == "1"
    }

    static func runIfRequested(
        kernel: KernelService,
        tun: TunService,
        systemProxy: SystemProxyService,
        model: PanelPreviewModel
    ) {
        let environment = ProcessInfo.processInfo.environment
        if environment["CLASH_AUDIT_A1"] == "1" {
            Task { @MainActor in
                let failures = await checkTunProxyExclusion(
                    model: model, tun: tun, kernel: kernel, systemProxy: systemProxy
                )
                print(failures == 0 ? "A1 DONE failures=0" : "A1 DONE failures=\(failures)")
                exit(failures == 0 ? 0 : 1)
            }
            return
        }
        if environment["CLASH_AUDIT_A4"] == "1" {
            Task { @MainActor in
                await holdTunForOrphanTest(tun: tun, kernel: kernel)
            }
            return
        }
        if environment["CLASH_AUDIT_A8"] == "1" {
            Task { @MainActor in
                await holdProxyForTerminationTest(systemProxy: systemProxy)
            }
            return
        }
        if environment["CLASH_AUDIT_A2"] == "1" {
            Task { @MainActor in
                let failures = await checkDestructiveGuards(kernel: kernel, model: model)
                print(failures == 0 ? "A2 DONE failures=0" : "A2 DONE failures=\(failures)")
                exit(failures == 0 ? 0 : 1)
            }
            return
        }
        if environment["CLASH_AUDIT_A3"] == "1" {
            Task { @MainActor in
                let failures = await checkLiveness(tun: tun, kernel: kernel)
                print(failures == 0 ? "A3 DONE failures=0" : "A3 DONE failures=\(failures)")
                exit(failures == 0 ? 0 : 1)
            }
        }
    }

    // MARK: - A4：第二实例 / 夹具不得回收正在使用的 TUN 内核

    /// `CLASH_AUDIT_A4=1`：开 TUN 并**保持**（不主动退出），供外部启动第二实例 / `kill -9` 取证。
    private static func holdTunForOrphanTest(tun: TunService, kernel: KernelService) async {
        await tun.enable()
        guard await waitUntilOn(tun: tun) else {
            print("A4 FAIL enable 未成功：\(tun.bannerMessage ?? "—")")
            exit(1)
        }
        let pid = ((try? await HelperClient.shared.kernelState()) ?? nil) ?? "?"
        print("A4 TUN ON pid=\(pid)")
        for _ in 0..<1200 { // 最多保持 10 分钟，或被外部 kill -9
            if tun.phase != .on {
                print("A4 TUN 被关闭 phase=\(tun.phase) banner=\(tun.bannerMessage ?? "—")")
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        await tun.disable(restartLocalKernel: false)
        if kernel.phase != .stopped { await kernel.stop() }
        exit(0)
    }

    // MARK: - A8：退出清理顺序

    /// `CLASH_AUDIT_A8=1`：用 App 真实的 `SystemProxyService` 打开系统代理并保持，
    /// 外部 `kill -TERM` 后由 `AppTerminationGuard` 收尾（它自己 `exit`）。
    private static func holdProxyForTerminationTest(systemProxy: SystemProxyService) async {
        do {
            try await systemProxy.enable(port: 7890)
            print("A8 PROXY ON snapshot=\(systemProxy.hasSnapshot) enabled=\(systemProxy.isEnabled)")
        } catch {
            print("A8 FAIL 开启系统代理：\(String(describing: error))")
            exit(1)
        }
        while true {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - A1：TUN 与系统代理互斥

    private static func checkTunProxyExclusion(
        model: PanelPreviewModel,
        tun: TunService,
        kernel: KernelService,
        systemProxy: SystemProxyService
    ) async -> Int {
        var failures = 0

        for round in 1...5 {
            // 保证起点：代理关、TUN 关（上一轮收尾）
            guard await waitUntil(model.isSystemProxyOn == false) else {
                print("FAIL A1 第 \(round) 轮起点：系统代理未关闭")
                return failures + 1
            }
            model.toggleConnection()
            // 「立刻」点 TUN：≤300ms（这里取 50ms，落在内核启动 / 代理写入的过渡窗口里）
            try? await Task.sleep(for: .milliseconds(50))
            let busyAtClick = model.isTunBusy
            model.toggleTun()
            try? await Task.sleep(for: .milliseconds(300))
            let tunTile = model.tunState
            let message = tun.failureMessage ?? "—"
            let blocked = tunTile == .off && !tun.isOn
            let overlap = tun.isOn && model.isSystemProxyOn
            print("A1 round=\(round) busy=\(busyAtClick) tunTile=\(tunTile.rawValue) banner=\(message) overlap=\(overlap)")
            if !busyAtClick { print("FAIL A1 第 \(round) 轮磁贴未被禁用"); failures += 1 }
            if !blocked { print("FAIL A1 第 \(round) 轮 TUN 被放行"); failures += 1 }
            if overlap { print("FAIL A1 第 \(round) 轮出现双接管"); failures += 1 }

            // 等代理稳定：必须真的 on，且 TUN 仍是关的
            guard await waitUntil(model.connectionState == .on, timeout: 30) else {
                print("FAIL A1 第 \(round) 轮代理未稳定")
                return failures + 1
            }
            if tun.isOn { print("FAIL A1 第 \(round) 轮代理稳定后 TUN 却在跑"); failures += 1 }
            // 关代理进入下一轮
            model.toggleConnection()
            _ = await waitUntil(model.connectionState == .off, timeout: 30)
        }

        // 代理稳定后再点 TUN：必须正常开启，且代理被关掉
        model.toggleConnection()
        guard await waitUntil(model.connectionState == .on, timeout: 30) else {
            print("FAIL A1 稳定态开启代理失败")
            return failures + 1
        }
        model.toggleTun()
        let tunOn = await waitUntil(tun.isOn, timeout: 30)
        print("A1 稳定后点 TUN → on=\(tunOn) proxyOn=\(model.isSystemProxyOn) banner=\(tun.bannerMessage ?? "—")")
        if !tunOn {
            print("FAIL A1 稳定后 TUN 未开启")
            failures += 1
        }
        if model.isSystemProxyOn {
            print("FAIL A1 TUN 开启后系统代理仍在")
            failures += 1
        }

        await cleanup(tun: tun, kernel: kernel, systemProxy: systemProxy)
        return failures
    }

    /// 收尾：TUN 关、代理关、本地内核停（夹具直接 `exit()`，不走 `AppTerminationGuard`）
    private static func cleanup(
        tun: TunService,
        kernel: KernelService,
        systemProxy: SystemProxyService
    ) async {
        if tun.isOn || tun.isHelperKernelRunning {
            await tun.disable(restartLocalKernel: false)
        }
        if systemProxy.isEnabled || systemProxy.hasSnapshot {
            systemProxy.disableSynchronouslyForTermination()
        }
        if kernel.phase != .stopped {
            await kernel.stop()
        }
    }

    private static func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeout: TimeInterval = 10
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    // MARK: - A2：破坏性操作的过渡守卫

    private static func checkDestructiveGuards(kernel: KernelService, model: PanelPreviewModel) async -> Int {
        var failures = 0
        let support = AppPaths.supportDirectory
        let existsBefore = FileManager.default.fileExists(atPath: support.path)
        let mtimeBefore = modificationDate(of: support)
        print("A2 前置 support=\(support.path) 存在=\(existsBefore) mtime=\(mtimeBefore?.description ?? "nil")")
        guard existsBefore else {
            print("FAIL A2 前置：应用数据目录不存在，无法验证「未被删除」")
            return 1
        }

        kernel.setTransitioningForAudit(true)
        defer { kernel.setTransitioningForAudit(false) }

        let results: [(String, String?)] = [
            ("performFullCleanup", await model.performFullCleanup()),
            ("installKernelIfMissing", await model.installKernelIfMissing()),
            ("updateKernel", await model.updateKernel(to: "v0.0.0-audit"))
        ]
        for (name, result) in results {
            let text = result ?? "nil"
            let blocked = text.contains("内核正在启动/更新")
            print("\(blocked ? "OK" : "FAIL") \(name) → \(text)")
            if !blocked { failures += 1 }
        }

        let existsAfter = FileManager.default.fileExists(atPath: support.path)
        let mtimeAfter = modificationDate(of: support)
        print("A2 后置 存在=\(existsAfter) mtime=\(mtimeAfter?.description ?? "nil")")
        if !existsAfter {
            print("FAIL A2 应用数据目录被删了")
            failures += 1
        }
        if mtimeBefore != mtimeAfter {
            print("FAIL A2 应用数据目录 mtime 变了：\(mtimeBefore?.description ?? "nil") → \(mtimeAfter?.description ?? "nil")")
            failures += 1
        }
        return failures
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - A3：TUN 活性校验

    private static func checkLiveness(tun: TunService, kernel: KernelService) async -> Int {
        var failures = 0

        // 第一段：心跳（30s 内发现内核被 kill）
        await tun.enable()
        guard await waitUntilOn(tun: tun) else {
            print("SKIP A3 前置 enable 未成功：\(tun.bannerMessage ?? "—")")
            return 0
        }
        var rootPID = "?"
        if let pid = (try? await HelperClient.shared.kernelState()) ?? nil { rootPID = pid }
        print("A3 READY pid=\(rootPID)")

        let killAt = ContinuousClock.now
        // 5s 后还没人动它（无第二个实例 / 外部 kill），自己请 helper 停掉，模拟「内核被其它进程关闭」
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if tun.phase == .on { try? await HelperClient.shared.stopKernel() }
        }
        var detectedAt: ContinuousClock.Instant?
        for _ in 0..<180 { // 45s 上限
            if tun.phase != .on { detectedAt = ContinuousClock.now; break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let heartbeatDetection = detectedAt.map { _ in ContinuousClock.now - killAt } ?? Duration.seconds(999)
        print("A3 心跳检测 phase=\(tun.phase) 用时=\(seconds(heartbeatDetection))s banner=\(tun.bannerMessage ?? "—")")
        if case .failed = tun.phase {} else {
            print("FAIL A3 心跳未把状态落到失败")
            failures += 1
        }
        if !(tun.bannerMessage ?? "").contains("内核已退出") {
            print("FAIL A3 banner 未说明内核已退出")
            failures += 1
        }
        if heartbeatDetection > Duration.seconds(31) {
            print("FAIL A3 心跳超过 30s 才纠正（\(seconds(heartbeatDetection))s）")
            failures += 1
        }

        // 第二段：打开面板（verifyLiveness）立即纠正
        // 先停掉上一段 `fail()` 回落的本地内核并等 7890 释放，否则 TUN 会卡在 portInUse
        try? await Task.sleep(for: .seconds(2)) // 给 fail() 的回落 Task 一点启动时间
        while kernel.isTransitioning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if kernel.phase != .stopped {
            await kernel.stop()
        }
        for _ in 0..<50 where !PortAllocator.isAvailable(port: kernel.settings.mixedPort) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await tun.enable()
        guard await waitUntilOn(tun: tun) else {
            print("SKIP A3 第二次 enable 未成功：\(tun.bannerMessage ?? "—")")
            return failures
        }
        rootPID = "?"
        if let pid = (try? await HelperClient.shared.kernelState()) ?? nil { rootPID = pid }
        print("A3 PANEL_READY pid=\(rootPID)")
        // 模拟「用户在面板打开前把内核关掉 / 内核被外部关闭」：请 helper 停掉后立刻校验
        try? await Task.sleep(for: .seconds(1))
        try? await HelperClient.shared.stopKernel()
        try? await Task.sleep(for: .seconds(1))
        let verifyAt = ContinuousClock.now
        await tun.verifyLiveness()
        let panelDetection = ContinuousClock.now - verifyAt
        print("A3 面板检测 phase=\(tun.phase) 用时=\(seconds(panelDetection))s banner=\(tun.bannerMessage ?? "—")")
        if case .failed = tun.phase {} else {
            print("FAIL A3 面板校验未把状态落到失败")
            failures += 1
        }
        if panelDetection > .seconds(2) {
            print("FAIL A3 面板校验超过 2s（\(seconds(panelDetection))s）")
            failures += 1
        }

        await tun.disable(restartLocalKernel: false)
        if kernel.phase != .stopped {
            await kernel.stop()
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

    private static func seconds(_ duration: Duration) -> String {
        let components = duration.components
        return String(format: "%.2f", Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }
}
#endif
