import AppKit

/// TUN 首次开启前的**我们自己的**说明卡（§4.2「授权前置说明」）。
///
/// 顺序刻意如此：先解释要做什么、写哪里、怎么撤销，用户确认后才可能弹 macOS 的密码框。
/// 不用 `PlaceholderPanel`（那是纯展示面板，没有按钮语义），这里要一次明确的「继续 / 取消」。
@MainActor
enum TunInstallPrompt {

    /// - Parameter updating: 已装但协议版本不符 → 文案换成「更新」，仍走同一次授权
    /// - Returns: 用户是否同意继续安装
    static func confirm(updating: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = updating ? "需要更新网络组件" : "需要管理员授权"
        alert.informativeText = """
        需要管理员密码安装网络组件，仅此一次。
        • 只写入 /Library/PrivilegedHelperTools 与 /Library/LaunchDaemons
        • 只用于开启 TUN 与系统代理，不读取任何个人数据
        • 可在设置里卸载
        """
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
