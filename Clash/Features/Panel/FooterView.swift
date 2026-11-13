import SwiftUI

/// 底部行 32pt：左「N 分钟前更新 + 刷新」，右 连接数 / 日志 / 设置（§3.2）。
@MainActor
struct FooterView: View {
    let updatedText: String
    /// 连接数；v0.1 没接 `/connections`，传 nil → 显示「—」，不编造数字
    let connectionCount: Int?
    /// 内核版本（如 `1.19.34`）；未运行传 nil → 显示「—」
    let kernelVersion: String?
    let onRefresh: () -> Void
    /// 底栏「连接」图标：推入连接列表二级页
    let onOpenConnections: () -> Void
    /// 底栏「日志」图标：打开独立日志窗口
    let onOpenLogs: () -> Void
    /// 底栏「设置」图标：推入面板内设置页（不再开独立窗口）
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(updatedText)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)

            IconButtonView(systemName: "arrow.clockwise", label: "刷新订阅", iconSize: 11) {
                onRefresh()
            }

            Spacer(minLength: 8)

            Text(versionText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .padding(.trailing, 8)
                .accessibilityLabel(versionLabel)

            HStack(spacing: 0) {
                IconButtonView(systemName: "link", label: "连接列表", iconSize: 13) {
                    onOpenConnections()
                }
                Text(connectionCount.map { "\($0)" } ?? "—")
                    .font(Typography.number)
                    .foregroundStyle(connectionCount == nil ? Theme.textTertiary : Theme.textSecondary)
                    .padding(.trailing, 4)
                    .accessibilityLabel(connectionCountLabel)
            }

            IconButtonView(systemName: "text.alignleft", label: "日志", iconSize: 12) {
                onOpenLogs()
            }

            IconButtonView(systemName: "gearshape", label: "设置", iconSize: 12) {
                onOpenSettings()
            }
        }
        .frame(height: Metrics.footerHeight)
    }

    private var connectionCountLabel: Text {        guard let connectionCount else { return Text("连接数未知") }
        return Text("连接数 \(connectionCount)")
    }

    /// 版本号统一带 `v` 前缀；未运行显示「—」，不编造
    private var versionText: String {
        guard let kernelVersion, !kernelVersion.isEmpty else { return "—" }
        return kernelVersion.hasPrefix("v") ? kernelVersion : "v\(kernelVersion)"
    }

    private var versionLabel: Text {
        guard let kernelVersion, !kernelVersion.isEmpty else { return Text("内核版本未知") }
        return Text("内核版本 \(versionText)")
    }
}
