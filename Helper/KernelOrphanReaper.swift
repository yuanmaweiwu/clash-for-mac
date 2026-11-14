import Darwin
import Foundation

/// helper 启动时的 root 内核孤儿回收（AUDIT A7）。
///
/// helper 被 launchd 重启（崩溃 / 升级 / `launchctl kickstart -k`）后，`KernelSupervisor`
/// 的内存句柄跟着进程一起没了，但上一个 helper 拉起的 mihomo 仍是 root、仍占着 mixed-port。
/// 此时任何新内核都起不来，而 App 侧 `kernelState()` 只认得「本 helper 当前的子进程」，
/// 会回报「没有内核」——用户看到的就是「TUN 关着却上不了网」的孤儿接管。
///
/// 所以**挂 XPC 监听之前**先按固定路径枚举并回收：`SIGTERM` → 等 2s → 仍活则 `SIGKILL`。
/// 判据与 App 侧 `KernelProcessIdentity` 同源：只认 `HelperLayout.kernelToolPath` 这个
/// 绝对路径，绝不按进程名模糊匹配（会误杀 ClashX / Clash Verge 的内核）。
enum KernelOrphanReaper {

    private static let terminationGrace: TimeInterval = 2
    private static let killGrace: TimeInterval = 0.5
    private static let pollInterval: TimeInterval = 0.05
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    /// 枚举并终止残留的 root 内核；返回**已确认退出**的 pid。
    ///
    /// helper 刚启动时还没有子进程，因此「路径匹配」的进程一定是上一个 helper 留下的；
    /// `parentPID != getpid()` 只是把这条语义写死，避免将来在别处复用时误杀自己的子进程。
    @discardableResult
    static func reapOrphans() -> [pid_t] {
        let orphans = allPIDs().filter { pid in
            guard pid != getpid(), isAlive(pid), parentPID(of: pid) != getpid() else { return false }
            guard let path = executablePath(of: pid) else { return false }
            return canonical(path) == canonical(HelperLayout.kernelToolPath)
        }

        guard !orphans.isEmpty else { return [] }

        HelperLog.notice("启动回收：发现 \(orphans.count) 个残留 root 内核 \(describe(orphans))")
        for pid in orphans {
            kill(pid, SIGTERM)
        }

        var remaining = waitUntilGone(orphans, within: terminationGrace)
        if !remaining.isEmpty {
            HelperLog.warning("启动回收：SIGTERM 超时，改用 SIGKILL \(describe(remaining))")
            for pid in remaining {
                kill(pid, SIGKILL)
            }
            remaining = waitUntilGone(remaining, within: killGrace)
        }

        let terminated = orphans.filter { !remaining.contains($0) }
        HelperLog.notice("启动回收：已终止 \(terminated.count) 个残留内核")
        if !remaining.isEmpty {
            HelperLog.error("启动回收：仍有 \(remaining.count) 个残留内核无法退出 \(describe(remaining))")
        }
        return terminated
    }

    // MARK: - libproc（与 App 侧 `OrphanKernelReaper` 同一套写法，不引新依赖）

    private static func allPIDs() -> [pid_t] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(estimated) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
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

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func waitUntilGone(_ pids: [pid_t], within timeout: TimeInterval) -> [pid_t] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let alive = pids.filter(isAlive)
            if alive.isEmpty { return [] }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return pids.filter(isAlive)
    }

    private static func describe(_ pids: [pid_t]) -> String {
        pids.map { "\($0)" }.joined(separator: ", ")
    }
}
