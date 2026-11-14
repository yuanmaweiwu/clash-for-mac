import SwiftUI

/// 底部行 32pt（§3.2）：左本 App 版本号，右「连接列表 / 规则 / 设置」三个图标。
///
/// 订阅的刷新 / 更新动作留在订阅管理页的 `⋯` 菜单里；日志只在右键菜单，
/// 面板底栏不再放「N 分钟前更新」、刷新按钮、连接数与内核版本号。
@MainActor
struct FooterView: View {
    /// 底栏「连接列表」图标：推入连接列表二级页
    let onOpenConnections: () -> Void
    /// 底栏「规则」图标：推入规则列表二级页
    let onOpenRules: () -> Void
    /// 底栏「设置」图标：推入面板内设置页（不再开独立窗口）
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(AppVersion.display)
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel(Text("版本 \(AppVersion.short ?? "未知")"))

            Spacer(minLength: Space.m)

            IconButtonView(systemName: "link", label: "连接列表", iconSize: 13) {
                onOpenConnections()
            }

            IconButtonView(systemName: "list.bullet.rectangle", label: "规则", iconSize: 13) {
                onOpenRules()
            }

            IconButtonView(systemName: "gearshape", label: "设置", iconSize: 12) {
                onOpenSettings()
            }
        }
        .frame(height: Metrics.footerHeight)
    }
}
