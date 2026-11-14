import Foundation
import Observation

/// 设置窗口「特权组件」一组的模型：状态查询 + 安装 / 更新 / 重新安装 / 卸载。
///
/// 状态来源（三条都要看，缺一条会误报）：
/// 1. `HelperInstaller.isInstalled`：文件在 + plist 在 + launchd 里 job 在
/// 2. `HelperClient.probe()`：helper 真的能应答（daemon 卡死时 job 仍是 running）
/// 3. `HelperRuntimeSnapshot.isLegacyPayload`：旧 helper 只回纯版本号，没有运行时自检
///
/// 「需要更新」有两个来源，UI 要能区分：
/// - 协议版本不一致（`probe.version != HelperVersion`）
/// - 版本一致但回的是旧格式（缺文件日志 / 富 ping）——升级后 `helper.log` 才会写
@MainActor
@Observable
final class HelperComponentModel {

    enum State: Equatable {
        case checking
        case notInstalled
        case installed(version: Int)
        case needsUpdate(installedVersion: Int, legacyPayload: Bool)
        /// 文件在但 launchd 没跑 / XPC 连不上
        case installedNotRunning
    }

    enum Action: Equatable {
        case install
        case update
        case reinstall
        case uninstall

        var title: String {
            switch self {
            case .install: "安装…"
            case .update: "更新组件…"
            case .reinstall: "重新安装…"
            case .uninstall: "卸载…"
            }
        }
    }

    private(set) var state: State = .checking
    private(set) var isWorking = false
    private(set) var notice: String?
    private(set) var noticeIsError = false

    @ObservationIgnored private let tun: TunService
    @ObservationIgnored private let client: HelperClient

    init(tun: TunService, client: HelperClient = .shared) {
        self.tun = tun
        self.client = client
    }

    // MARK: - 文案

    var statusText: String {
        switch state {
        case .checking:
            "正在检查…"
        case .notInstalled:
            "未安装"
        case .installed:
            "已安装"
        case .needsUpdate(let installedVersion, _):
            "需要更新（已装版本 \(installedVersion)）"
        case .installedNotRunning:
            "组件已安装但未运行"
        }
    }

    var hintText: String {
        switch state {
        case .checking:
            "TUN 需要管理员组件；正在读取组件状态"
        case .notInstalled:
            "TUN 需要管理员组件；安装时只需授权一次，只写入 /Library 下的两个固定位置"
        case .installed:
            "组件在运行。卸载会停止 TUN，系统代理与订阅不受影响"
        case .needsUpdate(_, let legacyPayload):
            legacyPayload
                ? "当前组件缺少文件日志与运行时自检，更新后才会写 helper.log"
                : "组件协议版本与 App 不一致，更新后才能继续使用 TUN"
        case .installedNotRunning:
            "文件已就位但 launchd 没在跑；重新安装可修复，TUN 暂不可用"
        }
    }

    /// 状态行右侧唯一的按钮（按状态互斥）
    var action: Action? {
        guard !isWorking else { return nil }
        return switch state {
        case .checking: nil
        case .notInstalled: .install
        case .needsUpdate: .update
        case .installedNotRunning: .reinstall
        case .installed: .uninstall
        }
    }

    var isStatusWarning: Bool {
        switch state {
        case .needsUpdate, .installedNotRunning: true
        case .checking, .notInstalled, .installed: false
        }
    }

    // MARK: - 查询

    /// 每次进设置窗口 / 动作结束后刷新。失败不抛错：状态本身就会说清问题。
    func refresh() async {
        let filesPresent = FileManager.default.fileExists(atPath: HelperLayout.helperToolPath)
            || FileManager.default.fileExists(atPath: HelperLayout.daemonPlistPath)

        guard HelperInstaller.isInstalled else {
            state = filesPresent ? .installedNotRunning : .notInstalled
            return
        }

        let snapshot: HelperRuntimeSnapshot
        do {
            snapshot = try await client.probe()
        } catch {
            // 刚装完 / 刚重装：旧 XPC 连接还没失效完，等一下再连一次（helper 由 launchd 拉起有延迟）
            try? await Task.sleep(for: .milliseconds(600))
            do {
                snapshot = try await client.probe()
            } catch {
                state = .installedNotRunning
                return
            }
        }

        if snapshot.version != HelperVersion {
            state = .needsUpdate(installedVersion: snapshot.version, legacyPayload: false)
        } else if snapshot.isLegacyPayload {
            state = .needsUpdate(installedVersion: snapshot.version, legacyPayload: true)
        } else {
            state = .installed(version: snapshot.version)
        }
    }

    #if DEBUG
    /// 仅自检 / 截图夹具：直接摆出某个状态，不触碰真实组件
    func applyPreviewState(_ state: State) {
        self.state = state
    }
    #endif

    // MARK: - 动作

    /// 执行当前状态对应的按钮动作（卸载的二次确认由视图负责）
    func perform() async {
        guard let action, !isWorking else { return }
        isWorking = true
        notice = nil
        defer { isWorking = false }

        // 安装 / 更新 / 卸载都会 bootout 当前 job：先把 TUN 优雅停掉，
        // 别让 root 内核被 launchd 突然拽掉（路由/utun 会留残局）
        if tun.isHelperKernelRunning {
            await tun.disable()
        }

        do {
            switch action {
            case .install, .update, .reinstall:
                try await HelperInstaller.install()
                notice = "组件已安装并运行"
            case .uninstall:
                try await HelperInstaller.uninstall()
                notice = "组件已卸载"
            }
            noticeIsError = false
        } catch let error as HelperInstallError {
            notice = error.userMessage
            noticeIsError = true
        } catch {
            notice = "组件操作失败：\(error.localizedDescription)"
            noticeIsError = true
        }

        await refresh()
    }
}
