import Foundation

/// TUN 首次开启前的**我们自己的**说明卡内容（§4.2「授权前置说明」）。
///
/// 呈现交给面板的 SwiftUI `.alert`，**不用 `NSAlert.runModal()`**：
/// 菜单栏浮层是 `.popUpMenu` 级面板，模态会话一旦不可见就会吞掉所有点击
/// （真机现象：磁贴点了没反应、也没有窗口出现）。
///
/// 顺序：先解释要做什么、写哪里、怎么撤销，用户点「继续」后才可能弹 macOS 密码框。
enum TunInstallPrompt {

    static func title(for blocker: TunService.TunInstallBlocker?) -> String {
        switch blocker {
        case .missingGeodata: "需要重新安装网络组件"
        case .outdated: "需要更新网络组件"
        case .notInstalled, .none: "需要管理员授权"
        }
    }

    /// 说明卡正文：默认是首次安装 / 更新；缺 geodata 时说清「为什么要再装一次」，
    /// 否则用户会以为刚装好的组件坏了。
    static func message(for blocker: TunService.TunInstallBlocker?) -> String {
        guard blocker == .missingGeodata else { return defaultMessage }
        return """
        网络组件运行目录缺少 geosite.dat，而当前订阅需要 GeoSite（规则或 DNS 策略里用到）。
        地理数据只在安装时拷入，所以需要重新安装一次组件把已下载的数据拷进去（需要管理员密码）。
        • 只写入 /Library/PrivilegedHelperTools 与 /Library/LaunchDaemons
        • 不重新下载订阅，也不改动现有设置
        • 可在设置里卸载
        """
    }

    private static let defaultMessage = """
    需要管理员密码安装网络组件，仅此一次。
    • 只写入 /Library/PrivilegedHelperTools 与 /Library/LaunchDaemons
    • 只用于开启 TUN 与系统代理，不读取任何个人数据
    • 可在设置里卸载
    """
}
