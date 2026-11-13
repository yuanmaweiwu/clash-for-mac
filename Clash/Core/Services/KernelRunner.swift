import Foundation

/// 内核进程生命周期的最小抽象。
///
/// v0.1 由 `LocalKernelRunner`（App 内用户态 `Process`，见 ADR-0007）实现；
/// helper 落地后新增 `HelperProcessRunner`（XPC）替换实现，`KernelService` 不动。
@MainActor
protocol KernelRunner: AnyObject {

    /// 进程是否在运行
    var isRunning: Bool { get }

    /// 最近一次退出码（尚未退出过为 nil）
    var lastExitCode: Int32? { get }

    /// stdout/stderr 落盘的日志文件
    var logFileURL: URL { get }

    /// 非用户主动停止的退出回调（崩溃 / 自行退出）
    var onExit: ((Int32) -> Void)? { get set }

    /// 启动内核，返回 pid。`-t` 校验由调用方在启动前完成。
    @discardableResult
    func start(configPath: URL) throws -> Int32

    /// `SIGTERM` → 3s → `SIGKILL`；返回时进程已退出
    func stop() async

    /// App 退出前的同步清理：只发 `SIGTERM`，不等待
    func terminateImmediately()
}
