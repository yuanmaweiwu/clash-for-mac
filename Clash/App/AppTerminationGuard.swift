import AppKit
import Foundation
import OSLog
import os

/// 进程退出前的系统清理：**正常退出与信号退出共用同一份幂等实现**。
///
/// 覆盖的退出路径：
/// 1. `applicationWillTerminate`（⌘Q / `osascript quit` / 菜单「退出」）→ `NSApplication.willTerminateNotification`
/// 2. `SIGTERM` / `SIGINT` / `SIGHUP`（`kill` / `launchctl` / 关机 / 注销）→ `DispatchSourceSignal`
///
/// 不归本类管的：内核异常退出、用户主动关代理（`PanelPreviewModel` 的常规路径）。
///
/// ## 为什么是 `DispatchSourceSignal`，而不是 `signal()` + 自建队列
/// `signal()` 的 handler 里只允许 async-signal-safe 函数：`Process`、`FileManager`、`Logger`
/// 以及 Swift 运行时的引用计数 / 元数据查找都不在其中，在 handler 里跑 `networksetup`
/// 属于未定义行为（典型后果是死锁在 malloc 或元数据锁上，比不清理更糟）。
/// 标准做法是 `signal(sig, SIG_IGN)` 关掉默认处置，再用 `DispatchSourceSignal` 把信号
/// 转成一个普通 block 投递到自建串行队列：清理照样同步执行（调用方在返回前完成全部 IO），
/// 但运行在普通上下文，不受信号安全约束。串行队列 + 原子标记同时挡住重入。
///
/// ## 刻意不处理的边界
/// - **`SIGKILL`（`kill -9`）拦不住**：进程收不到任何通知，直接消失。此时快照仍在盘上，
///   由下次启动的 `SystemProxyService.restoreIfNeeded(kernelRunning:)` 兜底还原
///   （实测：`kill -9` 后代理仍指向死端口，重启 App 即恢复）。
/// - 关机 / 注销 / 重启：系统会先给 App 发 `SIGTERM`（`launchd` 的 `ExitTimeOut` 内），
///   本类即覆盖；**不为关机引入 helper / `launchd` 钩子之类的新机制**。
/// - 清理有 3s 上限：宁可少还原一次（快照留着，下次启动兜底），也不留一个卡在退出流程里的
///   App —— 用户看到的是「App 无响应」，体验更差。
///
/// 常量放文件级：`@MainActor` 类型里的 `static let` 会被主 actor 隔离，信号队列上读不到。
private let terminationLogger = Logger(subsystem: "com.clash.app", category: "termination")
/// 清理总预算；超时 `exit(1)`
private let terminationCleanupBudget: TimeInterval = 3
/// 主线程等待预算：留 0.2s 余量，保证正常路径的 `exit` 先于硬超时
private let terminationMainHopTimeout: DispatchTimeInterval = .milliseconds(2900)
/// 拦截的信号：`kill` / `launchctl` / 关机注销都会发 `SIGTERM`
private let terminationHandledSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP]
/// `App.init` 正常只跑一次，但 SwiftUI 可能重建 App 值；重复装会出现两个 source
private let installTerminationGuardOnce = OSAllocatedUnfairLock(initialState: false)

@MainActor
final class AppTerminationGuard {

    private let kernel: KernelService
    private let systemProxy: SystemProxyService
    private let tun: TunService
    private let settings: SettingsStore

    /// 信号统一投递到这条串行队列：多个信号排队，第一个清理完就 `exit`，后面的没机会跑
    private let signalQueue = DispatchQueue(label: "com.clash.app.termination", qos: .userInitiated)
    /// 信号重入标记：清理期间到达的新信号直接丢弃（非隔离，只在 `signalQueue` 上读写）
    private let signalGate = OSAllocatedUnfairLock(initialState: false)
    /// 清理执行标记：`willTerminate` 与信号路径共用，保证只跑一次
    private let cleanupStarted = OSAllocatedUnfairLock(initialState: false)

    private var signalSources: [DispatchSourceSignal] = []
    private var terminateObserver: NSObjectProtocol?

    init(kernel: KernelService, systemProxy: SystemProxyService, tun: TunService, settings: SettingsStore) {
        self.kernel = kernel
        self.systemProxy = systemProxy
        self.tun = tun
        self.settings = settings

        let shouldInstall = installTerminationGuardOnce.withLock { installed -> Bool in
            guard !installed else { return false }
            installed = true
            return true
        }
        guard shouldInstall else { return }

        installTerminationObserver()
        installSignalHandlers()
    }

    // MARK: - 安装

    /// SwiftUI `App` 没有 `AppDelegate`；`willTerminateNotification` 就是 `applicationWillTerminate`
    private func installTerminationObserver() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runCleanup()
            }
        }
    }

    private func installSignalHandlers() {
        // 回调必须显式 `@Sendable`：否则闭包会继承本方法的 `@MainActor` 隔离，
        // 在信号队列上触发时先在闭包入口撞 `dispatch_assert_queue` 断言（SIGTRAP，
        // 实测过一次：进程被自己打死，代理没还原）。
        let handler: @Sendable () -> Void = { [weak self] in
            self?.handleSignalOnQueue()
        }

        for sig in terminationHandledSignals {
            // 必须先关掉默认处置：否则 SIGTERM 会在 source 投递 block 之前就杀掉进程
            signal(sig, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            source.setEventHandler(handler: handler)
            source.resume()
            signalSources.append(source)
        }
        terminationLogger.notice("已安装退出信号处理（SIGTERM / SIGINT / SIGHUP）")
    }

    // MARK: - 信号路径

    /// 在 `signalQueue` 上跑：把清理搬到主线程（服务是 `@MainActor`）并**阻塞等待**。
    /// 等待有上限，超时一律 `exit(1)`，绝不让进程卡在退出流程里。
    private nonisolated func handleSignalOnQueue() {
        // 重入：已在清理中，丢弃新信号（当前这轮一定会退出进程）
        let isFirst = signalGate.withLock { entered -> Bool in
            guard !entered else { return false }
            entered = true
            return true
        }
        guard isFirst else { return }

        let watchdog = DispatchWorkItem {
            terminationLogger.error("退出清理超过 \(terminationCleanupBudget)s，强制退出 code=1（快照留待下次启动兜底）")
            exit(1)
        }
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + terminationCleanupBudget, execute: watchdog)

        let finished = DispatchSemaphore(value: 0)
        let onMain: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                self.runCleanup()
            }
            finished.signal()
        }
        DispatchQueue.main.async(execute: onMain)

        let waitResult = finished.wait(timeout: .now() + terminationMainHopTimeout)
        watchdog.cancel()

        if waitResult == .timedOut {
            terminationLogger.error("退出清理未在 2.8s 内完成，强制退出 code=1（快照留待下次启动兜底）")
            exit(1)
        }
        exit(0)
    }

    // MARK: - 唯一清理实现

    /// 幂等、同步、顺序固定：
    /// 1. 先还原系统代理（按快照并发还原各网络服务，实测 4 个服务 ~0.9s）
    /// 2. TUN 开着就同步 `stopKernel`（root 内核不在本进程里，不发信号就永远在跑）
    /// 3. 再给本地内核发 `SIGTERM`
    /// 4. 最后落盘文本设置与延迟缓存（侧车缓存可能很大，不能挤占前 3 步的预算）
    ///
    /// 顺序不能反：内核先死会留下「代理指向死端口」的状态 = 用户断网。
    private func runCleanup() {
        let alreadyStarted = cleanupStarted.withLock { started -> Bool in
            guard !started else { return true }
            started = true
            return false
        }
        guard !alreadyStarted else { return }

        let began = Date()
        // 顺序（预算 3s 硬超时）：先还原系统代理（~0.9s），再停 TUN 内核，再停本地内核，
        // 最后才落盘文本设置 / 延迟缓存。落盘放最后：JSON 写入在侧车缓存大时能吃掉
        // 0.9s 预算，挤掉真正决定「用户是否断网」的代理还原。
        systemProxy.disableSynchronouslyForTermination()

        // helper 是 launchd 常驻，不会随 App 退出；TUN 的内核还在就会一直接管流量，
        // 而 App 已经消失 → 用户断网且没有 UI 可关。这里同步停一次（2s 上限，
        // 超时也算请求已投递，helper 会继续 SIGTERM → 3s → SIGKILL）。
        //
        // 预算：系统代理还原 ~0.9s + 这里 2.0s = 2.9s，略小于 3s 硬超时与 2.9s 主线程等待；
        // 真超时就按「先退出」处理，快照与路由兜底已经存在。
        if tun.isHelperKernelRunning {
            let confirmed = HelperClient.stopKernelSynchronously(timeout: 2.0)
            terminationLogger.notice(
                "退出前停止 TUN 内核：\(confirmed ? "已确认" : "未确认（请求已投递）", privacy: .public)"
            )
        }

        kernel.shutdownForTermination()

        // 文本设置是 300ms 合并写、延迟缓存是 1s 合并写：退出前都落盘
        settings.flushPendingWrite()
        LatencyCache.shared.flush()

        let elapsed = String(format: "%.3f", Date().timeIntervalSince(began))
        let snapshot = systemProxy.hasSnapshot ? "仍在" : "已删"
        terminationLogger.notice("退出清理完成 用时=\(elapsed, privacy: .public)s 快照=\(snapshot, privacy: .public)")
    }
}
