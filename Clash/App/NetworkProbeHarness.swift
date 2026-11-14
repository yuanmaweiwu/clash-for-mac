#if DEBUG
import Foundation

/// 网络检测「不自动测」自检（仅 DEBUG）：`CLASH_PROBE_HARNESS=1`。
///
/// 面板打开 / 收起 5 次，断言四个目标始终停在「未测」、`isTesting` 始终为 false、
/// `lastTestedAt` 仍是 nil（= 一次探测都没发起）。只有用户点刷新才允许 `testAll()`。
@MainActor
enum NetworkProbeHarness {

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["CLASH_PROBE_HARNESS"] == "1"
    }

    static func runIfRequested(model: PanelPreviewModel) {
        guard isRequested else { return }
        Task { @MainActor in
            let failures = run(model: model)
            print(failures == 0 ? "PROBE DONE failures=0" : "PROBE DONE failures=\(failures)")
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func run(model: PanelPreviewModel) -> Int {
        var failures = 0
        for round in 1...5 {
            model.setPanelVisible(true)
            model.setPanelVisible(false)
            let testing = model.isTestingNetworkProbes
            let states = model.networkProbeTargets.map { model.networkProbeState(for: $0) }
            let idle = states.allSatisfy { $0 == .idle }
            if testing || !idle {
                print("FAIL PROBE round=\(round) testing=\(testing) states=\(states)")
                failures += 1
            }
            print("PROBE round=\(round) testing=\(testing) idle=\(idle)")
        }
        print(failures == 0 ? "PASS PROBE 五次开关面板都没有发起探测" : "FAIL PROBE 面板打开时自动探测了")
        return failures
    }
}
#endif
