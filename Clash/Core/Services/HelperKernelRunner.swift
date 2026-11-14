import Foundation
import OSLog

/// `KernelRunner` 的 helper 实现：内核不在本 App 里，启动 / 停止全部经 XPC 交给 root helper。
///
/// 与 `LocalKernelRunner` 的差异（刻意保留，不做「统一抽象」）：
/// - **看不到进程**：`isRunning` 只是最近一次已知状态，真实性以 `/version` 就绪探测为准
/// - **读不到日志**：stdout/stderr 落在 `/Library/Application Support/ClashHelper/kernel.log`
/// - **不做配置校验**：`start(configPath:)` 读到的正文原样送 helper；`-t` 校验由调用方
///   （`TunService`）在本地包内 mihomo 上完成
/// - **停止要等回复**：helper 负责 `SIGTERM` → 3s → `SIGKILL`，App 只等结果
///
/// 退出路径不用这里的 `terminateImmediately()`：App 退出时主线程不能等 async，
/// 由 `AppTerminationGuard` 调 `HelperClient.stopKernelSynchronously`。
@MainActor
final class HelperKernelRunner: KernelRunner {

    private static let logger = Logger(subsystem: "com.clash.app", category: "helper")

    private let client: HelperClient

    private(set) var running = false
    private(set) var lastExitCode: Int32?
    var onExit: ((Int32) -> Void)?

    /// TUN 模式下 App 读不到 root 日志
    var logFileURL: URL? { nil }

    var isRunning: Bool { running }

    init(client: HelperClient = .shared) {
        self.client = client
    }

    // MARK: - 启动

    /// 启动：`applyRuntimeConfig`（写 root 配置）→ `startKernel`（spawn root 内核）。
    ///
    /// 两步分开是协议决定：写盘失败时不必先起内核再回滚，错误也更明确。
    @discardableResult
    func start(configData: Data) async throws -> Int32 {
        // AUDIT: 真机诊断——两步 XPC 各自的耗时（定位就绪预算被谁吃掉）
        let t0 = ContinuousClock.now
        try await client.applyRuntimeConfig(configData)
        let t1 = ContinuousClock.now
        LatencyTrace.shared.record("applyConfig", duration: t1 - t0)

        let detail = try await client.startKernel()
        let t2 = ContinuousClock.now
        LatencyTrace.shared.record("spawn", duration: t2 - t1)
        let pid = Self.pid(from: detail)
        running = true
        lastExitCode = nil
        let applyMs = Self.ms(from: t0, to: t1), spawnMs = Self.ms(from: t1, to: t2)
        Self.logger.notice("AUDIT helper start applyMs=\(applyMs) spawnMs=\(spawnMs) detail=\(detail ?? "nil", privacy: .public)")
        Self.logger.notice("helper 已启动内核 pid=\(pid) 配置=\(configData.count) bytes")
        return pid
    }

    private static func ms(from: ContinuousClock.Instant, to: ContinuousClock.Instant) -> Int {
        let d = to - from
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    /// `KernelRunner` 的门面：helper 不接受路径参数，这里只负责把文件读成正文再送过去。
    @discardableResult
    func start(configPath: URL) async throws -> Int32 {
        let data: Data
        do {
            data = try Data(contentsOf: configPath)
        } catch {
            throw KernelError.configInvalid(detail: "读取运行配置失败：\(error.localizedDescription)")
        }
        return try await start(configData: data)
    }

    // MARK: - 停止

    /// 协议门面：失败只记日志（`KernelRunner.stop()` 无 throws）。
    /// 需要「确认退出」语义的调用方（`TunService`）必须用 `stopThrowing()`。
    func stop() async {
        do {
            try await stopThrowing()
        } catch {
            // 停不下来时保守地标记仍在运行：宁可让上层以为「还开着」也不要谎报已停
            Self.logger.error("停止 TUN 内核失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 停止并要求 helper **确认退出**；失败抛错且 `running` 保持 true。
    ///
    /// 为什么单独开一个方法：XPC 停失败时 root 内核仍在接管流量，此时若上层把状态
    /// 置成「已关闭」，用户会以为 TUN 关了但实际流量还被劫持（P0）。
    func stopThrowing() async throws {
        try await client.stopKernel()
        running = false
        lastExitCode = nil
    }

    /// App 退出：XPC 是异步的，这里发不出去。
    /// 实际由 `AppTerminationGuard` → `HelperClient.stopKernelSynchronously` 完成。
    func terminateImmediately() {}

    // MARK: - 解析

    /// `startKernel` 成功时回 `pid=<n>`；解析不出来返回 `-1`（不阻塞启动，pid 只用于日志）
    private static func pid(from detail: String?) -> Int32 {
        guard let detail, detail.hasPrefix("pid="), let value = Int32(detail.dropFirst(4)) else {
            return -1
        }
        return value
    }
}
