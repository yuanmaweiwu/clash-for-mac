import Foundation

/// 分阶段耗时取样（`CLASH_LATENCY_BENCH`，见 `LatencyBenchHarness`）。
///
/// - Release：`enabled` 恒 `false`，`record` 直接返回（只有一次布尔判断的开销）
/// - DEBUG：进程启动时读一次 `CLASH_LATENCY_BENCH`；没设就同样零副作用
///
/// 只在「开关耗时」这条链路上打点（系统代理 / TUN / 组件脚本），不参与业务判断。
final class LatencyTrace: @unchecked Sendable {

    static let shared = LatencyTrace()

    private let lock = NSLock()
    private let enabled: Bool
    private var marks: [String: [Double]] = [:]

    private init() {
        #if DEBUG
        enabled = ProcessInfo.processInfo.environment["CLASH_LATENCY_BENCH"] != nil
        #else
        enabled = false
        #endif
    }

    /// 开一轮计时前清空上一次的取样
    func reset() {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        marks.removeAll(keepingCapacity: true)
    }

    /// 起点（未开启时也返回，调用方无需分支；`ContinuousClock` 读取是纳秒级）
    func begin() -> ContinuousClock.Instant {
        ContinuousClock.now
    }

    /// 记一段耗时（毫秒）
    func record(_ stage: String, from start: ContinuousClock.Instant) {
        guard enabled else { return }
        record(stage, duration: ContinuousClock.now - start)
    }

    func record(_ stage: String, duration: Duration) {
        guard enabled else { return }
        let ms = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        lock.lock()
        defer { lock.unlock() }
        marks[stage, default: []].append(ms)
    }

    /// 取走本轮取样（不清空；下一轮用 `reset()`）
    func snapshot() -> [String: [Double]] {
        guard enabled else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        return marks
    }

    /// 本阶段的最近一次耗时（毫秒）；没有取样时 nil
    func last(_ stage: String) -> Double? {
        snapshot()[stage]?.last
    }
}
