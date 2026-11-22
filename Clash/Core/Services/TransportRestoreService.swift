import Foundation
import OSLog

/// 开机恢复「上次的接管方式」（TUN / 系统代理）。
///
/// 与「实际状态」严格分开：`SettingsStore.lastTransport` 记录的是用户意图，只在用户
/// 主动开 / 关时写；退出清理、崩溃、服务内部启停都不改。启动时先由
/// `SystemProxyService.restoreIfNeeded()` 还原上次异常退出遗留的快照，再由本类按意图
/// 重新接管。
///
/// 约束：
/// - 第一次尝试前静默 1.5s：网络与 helper 刚起来，立刻抢路由容易得到「端口占用 / 冲突」
/// - 失败最多 3 次（间隔 2s / 5s），最终仍失败必须回一条给用户看的原因，不静默
/// - TUN 的组件没装 / 版本不齐 / daemon 没跑：直接跳过并提示，**绝不弹密码框**
/// - 用户中途自己点了 TUN / 代理：立即让位，不覆盖用户刚做的选择
@MainActor
final class TransportRestoreService {

    /// 第一次尝试前的静默期
    static let initialDelay: Duration = .milliseconds(1500)
    /// 失败后的重试间隔（第 2 次前 2s、第 3 次前 5s）
    static let retryDelays: [Duration] = [.seconds(2), .seconds(5)]
    /// 最多尝试次数（含第一次）
    static let maxAttempts = 3

    private static let logger = Logger(subsystem: "com.clash.app", category: "transport-restore")

    private let tun: TunService
    private let systemProxy: SystemProxyService
    private let client: HelperClient

    private enum Attempt {
        case success
        case retry(String)
        /// 前置条件不满足：不再重试，直接把这句话给用户
        case skip(String)
    }

    init(tun: TunService, systemProxy: SystemProxyService, client: HelperClient = .shared) {
        self.tun = tun
        self.systemProxy = systemProxy
        self.client = client
    }

    /// 按意图恢复接管方式。
    ///
    /// - Parameter enableProxy: 走与面板磁贴一致的「开系统代理」流程（含与 TUN 互斥、
    ///   等内核 running）。由 `PanelPreviewModel` 注入，避免本类反向依赖 UI 层。
    /// - Returns: 需要展示给用户的一句话（失败 / 跳过）；`nil` = 成功或无需恢复
    func restore(
        intent: TransportIntent,
        enableProxy: @MainActor () async throws -> Void
    ) async -> String? {
        guard intent != .off else { return nil }

        #if DEBUG
        if Self.failureInjected {
            Self.logger.notice("开机恢复被 CLASH_RESTORE_FAIL=1 注入为失败")
            return "开机恢复\(intent.displayName)失败：自检注入的失败（CLASH_RESTORE_FAIL=1）"
        }
        #endif

        // TUN 的前置检查放在延迟之前：组件都没装就没必要等网络
        if intent == .tun, let skip = await tunPreflight() {
            Self.logger.notice("跳过开机恢复 TUN：\(skip, privacy: .public)")
            return skip
        }

        do {
            try await Task.sleep(for: Self.initialDelay)
        } catch {
            return nil
        }

        var lastReason = "未知原因"
        for attempt in 1 ... Self.maxAttempts {
            if attempt > 1 {
                let delay = Self.retryDelays[min(attempt - 2, Self.retryDelays.count - 1)]
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return nil
                }
            }
            guard !Task.isCancelled else { return nil }

            // 用户已经自己接管（任一被打开）→ 让位，不覆盖刚做的选择
            if hasTakenOver {
                Self.logger.notice("用户已手动接管，放弃开机恢复\(intent.displayName, privacy: .public)")
                return nil
            }

            let outcome: Attempt
            switch intent {
            case .tun:
                outcome = await attemptTun()
            case .proxy:
                outcome = await attemptProxy(enableProxy: enableProxy)
            case .off:
                return nil
            }

            switch outcome {
            case .success:
                Self.logger.notice("开机恢复\(intent.displayName, privacy: .public)成功（第 \(attempt) 次）")
                return nil
            case .skip(let notice):
                Self.logger.notice("跳过开机恢复\(intent.displayName, privacy: .public)：\(notice, privacy: .public)")
                return notice
            case .retry(let reason):
                lastReason = reason
                Self.logger.error("开机恢复\(intent.displayName, privacy: .public)第 \(attempt) 次失败：\(reason, privacy: .public)")
            }
        }

        return "开机恢复\(intent.displayName)失败：\(lastReason)"
    }

    // MARK: - 单次尝试

    private func attemptTun() async -> Attempt {
        await tun.enable()
        if tun.isOn { return .success }
        // enable 在版本不符时会挂出安装说明卡：启动恢复不弹任何窗，先收起
        tun.dismissInstallPrompt()
        return .retry(tunFailureReason())
    }

    private func attemptProxy(enableProxy: @MainActor () async throws -> Void) async -> Attempt {
        do {
            try await enableProxy()
        } catch {
            return .retry(Self.describe(error))
        }
        guard systemProxy.isEnabled else {
            return .retry(systemProxy.lastError?.userMessage ?? "系统代理未生效")
        }
        return .success
    }

    /// TUN 组件前置：只查状态，不触发安装 / 授权
    private func tunPreflight() async -> String? {
        guard HelperInstaller.isInstalled else {
            return "开机恢复 TUN 失败：管理员组件未安装，可在设置里安装后手动开启"
        }
        do {
            _ = try await client.checkVersion()
            return nil
        } catch HelperClientError.versionMismatch {
            return "开机恢复 TUN 失败：管理员组件需要更新，请在设置里更新后手动开启"
        } catch {
            return "开机恢复 TUN 失败：管理员组件未运行，请重启电脑后手动开启"
        }
    }

    private var hasTakenOver: Bool {
        tun.isOn || tun.isBusy || systemProxy.isEnabled || systemProxy.isTransitioning
    }

    private func tunFailureReason() -> String {
        if case .failed(let failure) = tun.phase {
            let text = failure.userMessage
            let prefix = "TUN 未开启："
            return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
        }
        if case .needsInstall = tun.phase {
            return "管理员组件需要授权或更新"
        }
        return tun.failureMessage ?? "TUN 未能开启"
    }

    private static func describe(_ error: Error) -> String {
        if let proxyError = error as? SystemProxyError { return proxyError.userMessage }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    #if DEBUG
    /// 自检注入（仅 DEBUG）：`CLASH_RESTORE_FAIL=1` 时直接走失败分支，
    /// 用来验证「不崩溃、不弹密码框、给 notice」而不必真的破坏 helper。
    private static var failureInjected: Bool {
        ProcessInfo.processInfo.environment["CLASH_RESTORE_FAIL"] == "1"
    }
    #endif
}
