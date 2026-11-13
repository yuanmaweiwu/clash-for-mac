import Foundation

/// TUN 首次开启前的**我们自己的**说明卡内容（§4.2「授权前置说明」）。
///
/// 呈现交给面板的 SwiftUI `.alert`，**不用 `NSAlert.runModal()`**：
/// 菜单栏浮层是 `.popUpMenu` 级面板，模态会话一旦不可见就会吞掉所有点击
/// （真机现象：磁贴点了没反应、也没有窗口出现）。
///
/// 顺序：先解释要做什么、写哪里、怎么撤销，用户点「继续」后才可能弹 macOS 密码框。
enum TunInstallPrompt {

    static func title(updating: Bool) -> String {
        updating ? "需要更新网络组件" : "需要管理员授权"
    }

    static let message = """
    需要管理员密码安装网络组件，仅此一次。
    • 只写入 /Library/PrivilegedHelperTools 与 /Library/LaunchDaemons
    • 只用于开启 TUN 与系统代理，不读取任何个人数据
    • 可在设置里卸载
    """
}
