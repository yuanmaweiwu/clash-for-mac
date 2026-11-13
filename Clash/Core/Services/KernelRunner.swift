import Foundation

/// 内核进程生命周期的最小抽象。
///
/// 两个实现：
/// - `LocalKernelRunner`：App 内用户态 `Process`（ADR-0007），无 TUN
/// - `HelperKernelRunner`：XPC 交给 root helper 启动（TUN），App 只持有 API 端点
///
/// 刻意保持「薄」：不生成配置、不做就绪判定，那些都在 `KernelService` / `TunService` 里。
@MainActor
protocol KernelRunner: AnyObject {

    /// 进程是否在运行。
    ///
    /// 本地实现直接读 `Process.isRunning`；helper 实现只能返回最近一次已知状态
    /// （App 看不到 root 进程），真实性由 API 就绪探测兜底。
    var isRunning: Bool { get }

    /// 最近一次退出码（尚未退出过为 nil；helper 实现恒为 nil）
    var lastExitCode: Int32? { get }

    /// stdout/stderr 落盘的日志文件。
    ///
    /// helper 实现返回 `nil`：日志在 root 目录（`HelperLayout.kernelLogPath`），App 读不到。
    var logFileURL: URL? { get }

    /// 非用户主动停止的退出回调（崩溃 / 自行退出）
    var onExit: ((Int32) -> Void)? { get set }

    /// 启动内核，返回 pid。`-t` 校验由调用方在启动前完成。
    ///
    /// `async` 是因为 helper 实现要走 XPC（写配置 + 启动两步往返）。
    @discardableResult
    func start(configPath: URL) async throws -> Int32

    /// `SIGTERM` → 3s → `SIGKILL`；返回时进程已退出
    func stop() async

    /// App 退出前的同步清理：只发 `SIGTERM`，不等待
    func terminateImmediately()
}
