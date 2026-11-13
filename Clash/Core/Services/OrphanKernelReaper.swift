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
/// 匹配方式：`proc_pidpath` 取进程可执行路径，与包内 mihomo 路径做「标准化后完全相等」
/// 比较。**绝不按进程名匹配**：ClashX 自带的内核、用户自己跑的 mihomo 同名但路径不同，
/// 按名字杀会误伤。
enum OrphanKernelReaper {

    private static let logger = Logger(subsystem: "com.clash.app", category: "kernel")
    private static let terminationGrace: Duration = .seconds(2)
    private static let killGrace: Duration = .milliseconds(500)
    private static let pollInterval: Duration = .milliseconds(50)
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    /// 枚举 → `SIGTERM` → 最多等 2s → 仍在则 `SIGKILL` → 等待退出。
    ///
    /// 返回**已确认退出**的 pid；`SIGKILL` 仍杀不掉的由调用方的端口检查兜住（报 `portInUse`）。
    /// 枚举 / 路径读取失败一律当作「没有孤儿」，不阻塞启动。
    @discardableResult
    static func reapOrphans(matching binaryURL: URL) async -> [pid_t] {
        let target = canonicalPath(of: binaryURL.path)
        let orphans = allPIDs().filter { pid in
            guard pid != getpid(), isAlive(pid) else { return false }
            guard let path = executablePath(of: pid) else { return false }
            return canonicalPath(of: path) == target
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
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map(UInt8.init(bitPattern:)), as: UTF8.self)
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

    // MARK: - 路径规范化

    /// `/var` ↔ `/private/var`、软链接、`..` 统一后再比较，避免同一文件两种写法被漏判
    private static func canonicalPath(of path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func describe(_ pids: [pid_t]) -> String {
        pids.map(String.init).joined(separator: ", ")
    }
}
