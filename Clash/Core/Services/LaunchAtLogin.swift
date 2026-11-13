import Foundation
import OSLog
import ServiceManagement

/// 开机自启：`SMAppService.mainApp`（macOS 13+）。
///
/// 本地 ad-hoc 签名的构建常被系统拒绝（`register()` 抛 `Operation not permitted`），
/// 这里只做「尝试 + 回报真实状态」，失败必须给可操作提示，不静默吞错。
@MainActor
enum LaunchAtLogin {

    private static let logger = Logger(subsystem: "com.clash.app", category: "settings")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 当前真实状态（UI 展示 / 排查用）
    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "已启用"
        case .notRegistered: "未登记"
        case .requiresApproval: "等待批准"
        case .notFound: "未找到"
        @unknown default: "未知"
        }
    }

    /// 被系统拒绝时的可操作提示
    static let failureHint = "当前构建为本地签名，系统可能拒绝；可在「系统设置 → 通用 → 登录项」手动添加"

    /// 注册 / 注销登录项；抛错表示系统拒绝（调用方要把真实状态显示出来）
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
        logger.notice("登录项已\(enabled ? "登记" : "移除")，status=\(statusText, privacy: .public)")
    }
}
