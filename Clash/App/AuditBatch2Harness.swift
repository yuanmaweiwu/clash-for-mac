#if DEBUG
import Foundation

/// 审核批次 2（`docs/AUDIT-2026-11-14.md`）的真机自检夹具，仅 DEBUG。
///
/// - `CLASH_AUDIT_B1=1`：开 TUN → 模拟「helper 仍有内核但 App 失忆」（不 stopKernel）→
///   再开 TUN。验证 `TunService.enableInternal` 的预检先停旧内核、再按新配置 spawn，
///   最终 `/version` 可达。旧 pid 消失时刻用来核对「300ms 内 stopKernel」。
/// - `CLASH_AUDIT_B4=1`：0.2s 间隔连切两条订阅 5 次，验证新请求取消旧启动、
///   最终等于最后一次选择，且全程不出现 `startTimeout`。
///
/// 输出直接打 stdout，供真机验收贴回；夹具自己清理（TUN 关、内核停）后 `exit`。
@MainActor
enum AuditBatch2Harness {

    static var isRequested: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CLASH_AUDIT_B1"] == "1" || environment["CLASH_AUDIT_B4"] == "1"
    }

    static func runIfRequested(
        kernel: KernelService,
        tun: TunService,
        systemProxy: SystemProxyService,
        model: PanelPreviewModel
    ) {
        let environment = ProcessInfo.processInfo.environment
        if environment["CLASH_AUDIT_B1"] == "1" {
            Task { @MainActor in
                let failures = await checkTunPreflight(tun: tun, kernel: kernel, systemProxy: systemProxy)
                print(failures == 0 ? "B1 DONE failures=0" : "B1 DONE failures=\(failures)")
                exit(failures == 0 ? 0 : 1)
            }
            return
        }
        if environment["CLASH_AUDIT_B4"] == "1" {
            Task { @MainActor in
                let failures = await checkRapidSubscriptionSwitch(
                    model: model, kernel: kernel, tun: tun, systemProxy: systemProxy
                )
                print(failures == 0 ? "B4 DONE failures=0" : "B4 DONE failures=\(failures)")
                exit(failures == 0 ? 0 : 1)
            }
        }
    }

    // MARK: - B1：TUN 启动前预检 helper 已有内核

    private static func checkTunPreflight(
        tun: TunService,
        kernel: KernelService,
        systemProxy: SystemProxyService
    ) async -> Int {
        var failures = 0

        // 前置：本地内核 / 系统代理让位（夹具不自动起内核）
        if systemProxy.isEnabled || systemProxy.hasSnapshot {
            systemProxy.disableSynchronouslyForTermination()
        }
        while kernel.isTransitioning { try? await Task.sleep(for: .milliseconds(100)) }
        if kernel.phase != .stopped { await kernel.stop() }
        let mixedPort = kernel.settings.mixedPort
        let helperPID = (try? await HelperClient.shared.kernelState()) ?? nil
        if !PortAllocator.isAvailable(port: mixedPort) {
            let occupant = await PortOccupantProbe.listener(onPort: mixedPort)
            guard helperPID != nil else {
                print("SKIP B1 前置：mixed-port \(mixedPort) 被 \(occupant?.summary ?? "未知进程") 占用")
                return 0
            }
            print("B1 前置：mixed-port \(mixedPort) 被 helper root 内核 pid=\(helperPID!) 占用（正是要回收的场景）")
        }

        await tun.enable()
        guard await waitUntilOn(tun: tun) else {
            print("SKIP B1 前置 enable 未成功：\(tun.bannerMessage ?? "—")")
            return 0
        }
        let oldPID = ((try? await HelperClient.shared.kernelState()) ?? nil) ?? "?"
        print("B1 TUN ON oldPid=\(oldPID)")

        // 模拟 App 失忆：helper 仍有 root 内核，但本进程 phase=off / hasHelperKernel=false
        tun.simulateForgottenHelperKernelForAudit()
        let stillThere = ((try? await HelperClient.shared.kernelState()) ?? nil) ?? "?"
        print("B1 失忆后 phase=\(tun.phase) helperPid=\(stillThere)")
        if stillThere != oldPID {
            print("FAIL B1 失忆时 helper 内核已不在（\(stillThere) != \(oldPID)）")
            failures += 1
        }

        let began = Date()
        await tun.enable()
        let reopened = await waitUntilOn(tun: tun)
        let elapsed = Date().timeIntervalSince(began)
        guard reopened else {
            print("FAIL B1 重开失败：\(tun.bannerMessage ?? "—")")
            await cleanup(tun: tun, kernel: kernel, systemProxy: systemProxy)
            return failures + 1
        }
        let newPID = ((try? await HelperClient.shared.kernelState()) ?? nil) ?? "?"
        let version = kernel.kernelVersion ?? "-"
        print("B1 重开完成 用时=\(String(format: "%.2f", elapsed))s oldPid=\(oldPID) newPid=\(newPID) version=\(version)")
        if oldPID == newPID {
            print("FAIL B1 内核未换 pid（旧进程被复用，配置不会重载）")
            failures += 1
        }
        if version == "-" || version.isEmpty {
            print("FAIL B1 新内核 /version 不可达")
            failures += 1
        }
        if elapsed > 6 {
            print("FAIL B1 重开耗时 \(String(format: "%.2f", elapsed))s（应远小于 8s 就绪超时）")
            failures += 1
        }

        // helper.log 是唯一能看到 stopKernel 时序的地方（root 0644 可读），由外部脚本核对
        print("B1 取证：helper.log 最后一条 stopKernel 应早于新内核启动，oldPid=\(oldPID)")
        await cleanup(tun: tun, kernel: kernel, systemProxy: systemProxy)
        return failures
    }

    // MARK: - B4：快速连切订阅

    private static func checkRapidSubscriptionSwitch(
        model: PanelPreviewModel,
        kernel: KernelService,
        tun: TunService,
        systemProxy: SystemProxyService
    ) async -> Int {
        var failures = 0

        if tun.isOn || tun.isHelperKernelRunning {
            await tun.disable(restartLocalKernel: false)
        }
        if systemProxy.isEnabled || systemProxy.hasSnapshot {
            systemProxy.disableSynchronouslyForTermination()
        }

        let subscriptions = model.subscriptions
        guard subscriptions.count >= 2 else {
            print("SKIP B4 需要两条订阅，当前 \(subscriptions.map(\.name))")
            return 0
        }
        let originalID = model.activeSubscriptionID
        let targets: [(name: String, id: String)] = subscriptions.prefix(2).map { ($0.name, $0.id) }
        print("B4 目标订阅 \(targets.map { "\($0.name)=\($0.id)" }.joined(separator: ", "))")
        print("B4 起点 active=\(model.activeSubscriptionID ?? "nil") phase=\(kernel.phase)")

        // 轮询记录过程中是否出现 startTimeout（内核 lastError 会在下一次 start 开始时清零）
        var sawStartTimeout = false
        var sawFailedPhase = false
        let poller = Task { @MainActor in
            for _ in 0..<600 {
                if kernel.lastError == .startTimeout { sawStartTimeout = true }
                if kernel.phase == .failed { sawFailedPhase = true }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        let began = Date()
        var lastID = targets[0].id
        for round in 0..<5 {
            let target = targets[round % 2]
            lastID = target.id
            model.activateSubscription(target.id)
            print("B4 round=\(round + 1) activate \(target.name) active=\(model.activeSubscriptionID ?? "nil")")
            try? await Task.sleep(for: .milliseconds(200))
        }

        let settled = await waitUntil(timeout: 60) {
            kernel.phase == .running && !kernel.isTransitioning
        }
        let elapsed = Date().timeIntervalSince(began)
        poller.cancel()

        print("B4 收敛 settled=\(settled) 用时=\(String(format: "%.2f", elapsed))s "
            + "active=\(model.activeSubscriptionID ?? "nil") phase=\(kernel.phase) "
            + "version=\(kernel.kernelVersion ?? "-") lastError=\(String(describing: kernel.lastError))")
        if !settled {
            print("FAIL B4 内核未收敛到 running")
            failures += 1
        }
        if model.activeSubscriptionID != lastID {
            print("FAIL B4 最终订阅不是最后一次选择（\(model.activeSubscriptionID ?? "nil") != \(lastID)）")
            failures += 1
        }
        if kernel.phase != .running {
            print("FAIL B4 最终 phase=\(kernel.phase)")
            failures += 1
        }
        if kernel.kernelVersion == nil {
            print("FAIL B4 最终 /version 不可达")
            failures += 1
        }
        if sawStartTimeout {
            print("FAIL B4 过程中出现 startTimeout（旧启动跑满了超时）")
            failures += 1
        }
        if sawFailedPhase {
            print("FAIL B4 过程中出现过 failed（失败应被取消让位，而不是落失败态）")
            failures += 1
        }
        print("B4 取证：本地内核日志里真实 `启动 mihomo pid=` 次数应 ≤ 2（首启 + 末次）")

        // 收尾：订阅恢复为开始时的那条，内核停掉，TUN / 代理保持关闭
        if let originalID {
            model.activateSubscription(originalID)
            _ = await waitUntil(timeout: 60) { kernel.phase == .running && !kernel.isTransitioning }
        }
        await cleanup(tun: tun, kernel: kernel, systemProxy: systemProxy)
        return failures
    }

    // MARK: - 工具

    private static func cleanup(
        tun: TunService,
        kernel: KernelService,
        systemProxy: SystemProxyService
    ) async {
        if tun.isOn || tun.isHelperKernelRunning {
            await tun.disable(restartLocalKernel: false)
        }
        // 夹具直接 `exit()`：phase 可能已 failed / 失忆，`disable` 会提前返回，
        // 这里按 helper 的真实状态兜一次
        if let pid = (try? await HelperClient.shared.kernelState()) ?? nil, !pid.isEmpty {
            print("CLEANUP 停止残留 root 内核 pid=\(pid)")
            try? await HelperClient.shared.stopKernel()
        }
        if systemProxy.isEnabled || systemProxy.hasSnapshot {
            systemProxy.disableSynchronouslyForTermination()
        }
        if kernel.phase != .stopped {
            await kernel.stop()
        }
    }

    private static func waitUntilOn(tun: TunService) async -> Bool {
        for _ in 0..<160 {
            if tun.isOn { return true }
            if case .failed = tun.phase { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}
#endif
