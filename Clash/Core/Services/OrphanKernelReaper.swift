import Darwin
import Foundation
import OSLog

/// 孤儿内核清理（`core-process` §2「孤儿清理」）。
///
/// App 被 `SIGKILL` / 系统强杀时，`AppTerminationGuard` 完全没机会执行，内核会被 launchd
/// 收留并继续持有 `mixed-port` 与 `/proxies`；下次启动再拉一个内核就会出现两个 mihomo
/// 抢 7890。这里只负责这种强杀后的**唯一兜底**——正常退出 / `SIGTERM` 路径已由
/// `AppTerminationGuard` 处理，不要在别处调用。
///
/// 匹配方式：`proc_pidpath` 取进程可执行路径，按 `KernelProcessIdentity` 的**路径段精确
/// 匹配**判据：路径以 `/Clash.app/Contents/Resources/Kernel/mihomo` 结尾即视为本产品内核，
/// 因此 DerivedData、`/Applications` 与任意目录下的副本都会被回收（换构建跑一版后旧内核
/// 占着 7890 就是这个场景）。**绝不按进程名匹配**：ClashX / Clash Verge 自带的内核同名但
/// 路径不同，按名字杀会误伤。
enum OrphanKernelReaper {

    private static let logger = Logger(subsystem: "com.clash.app", category: "kernel")
    private static let terminationGrace: Duration = .seconds(2)
    private static let killGrace: Duration = .milliseconds(500)
    private static let pollInterval: Duration = .milliseconds(50)

    /// 枚举 → `SIGTERM` → 最多等 2s → 仍在则 `SIGKILL` → 等待退出。
    ///
    /// 返回**已确认退出**的 pid；`SIGKILL` 仍杀不掉的由调用方的端口检查兜住（报 `portInUse`）。
    /// 枚举 / 路径读取失败一律当作「没有孤儿」，不阻塞启动。
    ///
    /// helper 的 root 内核（`/Library/PrivilegedHelperTools/mihomo`）不在判据内：
    /// 它只存在于 TUN 模式，由 `TunService` 管；这里只靠端口诊断报明确错误，不 kill root。
    @discardableResult
    static func reapOrphans() async -> [pid_t] {
        let orphans = allPIDs().filter { pid in
            guard pid != getpid(), isAlive(pid) else { return false }
            guard let path = KernelProcessIdentity.executablePath(of: pid),
                  KernelProcessIdentity.isProductKernel(path: path) else { return false }
            // 本进程自己拉起、仍在跑的内核不是孤儿（正常重启会先 `stop()`，这里只是兜底）
            return parentPID(of: pid) != getpid()
        }

        guard !orphans.isEmpty else {
            logger.debug("未发现孤儿内核")
            return []
        }

        logger.notice("发现 \(orphans.count, privacy: .public) 个孤儿内核：\(describe(orphans), privacy: .public)")
        for pid in orphans {
            kill(pid, SIGTERM)
        }

        var remaining = await waitUntilGone(orphans, within: Self.terminationGrace)
        if !remaining.isEmpty {
            logger.warning("SIGTERM 超时，改用 SIGKILL：\(describe(remaining), privacy: .public)")
            for pid in remaining {
                kill(pid, SIGKILL)
            }
            remaining = await waitUntilGone(remaining, within: Self.killGrace)
        }

        let terminated = orphans.count - remaining.count
        logger.notice("已终止 \(terminated, privacy: .public) 个孤儿内核")
        if !remaining.isEmpty {
            logger.error("仍有 \(remaining.count, privacy: .public) 个孤儿内核未能退出：\(describe(remaining), privacy: .public)")
        }
        return orphans.filter { !remaining.contains($0) }
    }

    // MARK: - libproc

    private static func allPIDs() -> [pid_t] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else {
            logger.error("proc_listallpids 探测失败")
            return []
        }

        // 枚举与使用之间有新进程 spawn 的可能，多留余量；不够再按返回数量取一次
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else {
            logger.error("proc_listallpids 读取失败")
            return []
        }
        return Array(pids.prefix(Int(count)))
    }

    private static func executablePath(of pid: pid_t) -> String? {
        KernelProcessIdentity.executablePath(of: pid)
    }

    /// 父进程 pid：跳过本进程自己拉起的内核用
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    // MARK: - 进程状态

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func waitUntilGone(_ pids: [pid_t], within timeout: Duration) async -> [pid_t] {
        let deadline = ContinuousClock.now + timeout
        var alive = pids
        while ContinuousClock.now < deadline {
            alive = pids.filter(isAlive)
            if alive.isEmpty { return [] }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return pids.filter(isAlive)
    }

    // MARK: - 描述

    /// 日志里带上路径：区分「DerivedData 那份」和「/Applications 那份」是排查的关键
    private static func describe(_ pids: [pid_t]) -> String {
        pids.map { pid in
            guard let path = executablePath(of: pid) else { return String(pid) }
            return "\(pid)(\(path))"
        }
        .joined(separator: ", ")
    }
}
