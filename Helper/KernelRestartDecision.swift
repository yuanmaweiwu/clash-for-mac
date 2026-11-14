import Darwin
import Foundation

/// 复用既有内核前的「配置是否比进程新」判定（AUDIT A7 · 配置复用）。
///
/// `KernelSupervisor.startLocked()` 见到运行中的进程会直接复用，但 App 可能刚把新的
/// `runtime.yaml` 写进 helper 目录（切订阅 / 改端口 / 改日志级别）。helper 无法从 XPC
/// 感知「配置写了几次」，只能比较文件 mtime 与进程启动时间：**配置比进程新就必须重启**，
/// 否则新 controller 端口 / 新正文永远不会生效。
///
/// 抽成纯函数是为了可测：`CLASH_HELPER_SELFCHECK=1` 时 `main` 会打印下面这张判定表。
func shouldRestartKernel(configMtime: Date, processStart: Date) -> Bool {
    // 1ms 容差：两次写盘 / 进程启动记录的分辨率不同，「同一时刻」不该被当成配置更新
    configMtime.timeIntervalSince(processStart) > 0.001
}

/// 进程启动时间（`PROC_PIDTBSDINFO` 的 `pbi_start_tvsec/tvusec`）
enum KernelProcessClock {

    static func startDate(pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let seconds = TimeInterval(info.pbi_start_tvsec)
        let micros = TimeInterval(info.pbi_start_tvusec) / 1_000_000
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds + micros)
    }
}

#if DEBUG
/// helper 自检入口（仅 DEBUG）：`CLASH_HELPER_SELFCHECK=1` 时打印配置新鲜度判定表并退出。
///
/// 为什么放在 helper 进程里：`shouldRestartKernel` 是 helper 目标的代码，App 测试 target
/// 还不存在；直接跑 Debug 产物的这个入口，等于对它做一次「单测式验证」，不需要 root。
enum HelperSelfCheck {

    /// 返回 `true` 表示已执行自检并 `exit`（调用方不必继续挂 XPC）
    static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["CLASH_HELPER_SELFCHECK"] == "1" else {
            return false
        }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(name: String, config: Date, process: Date, expected: Bool)] = [
            ("配置比进程新 1s", base.addingTimeInterval(1), base, true),
            ("配置比进程新 0.5ms", base.addingTimeInterval(0.0005), base, false),
            ("配置与进程同时", base, base, false),
            ("配置比进程旧 10s", base.addingTimeInterval(-10), base, false),
        ]

        var failures = 0
        print("SELFCHECK shouldRestartKernel 判定表")
        for item in cases {
            let actual = shouldRestartKernel(configMtime: item.config, processStart: item.process)
            let passed = actual == item.expected
            print("\(passed ? "PASS" : "FAIL") \(item.name)：config=\(item.config.timeIntervalSince1970) "
                + "process=\(item.process.timeIntervalSince1970) expected=\(item.expected) actual=\(actual)")
            if !passed { failures += 1 }
        }

        // A7 孤儿判定：只吃 libproc 的事实，纯函数可复跑
        print("SELFCHECK KernelOrphanReaper.shouldReap 判定表")
        let kernelPath = HelperLayout.kernelToolPath
        let orphanCases: [(name: String, pid: pid_t, parent: pid_t?, path: String?, expected: Bool)] = [
            ("同路径、非子进程 → 回收", 100, 1, kernelPath, true),
            ("路径带冗余斜杠 → 回收", 100, 1, "/Library//PrivilegedHelperTools/mihomo", true),
            ("候选就是自己 → 不回收", 42, 1, kernelPath, false),
            ("候选是自己的子进程 → 不回收", 100, 42, kernelPath, false),
            ("路径不同（别家内核）→ 不回收", 100, 1, "/usr/local/bin/mihomo", false),
            ("取不到路径 → 不回收", 100, 1, nil, false),
        ]
        for item in orphanCases {
            let actual = KernelOrphanReaper.shouldReap(
                candidatePID: item.pid,
                parentPID: item.parent,
                executablePath: item.path,
                selfPID: 42,
                kernelToolPath: kernelPath
            )
            let passed = actual == item.expected
            print("\(passed ? "PASS" : "FAIL") \(item.name)：expected=\(item.expected) actual=\(actual)")
            if !passed { failures += 1 }
        }

        print(failures == 0 ? "SELFCHECK DONE failures=0" : "SELFCHECK DONE failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
