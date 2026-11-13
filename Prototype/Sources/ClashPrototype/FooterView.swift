import AppKit
import SwiftUI

/// 底部行 32pt：左「N 分钟前更新 + 刷新」，右 连接数 / 日志 / 设置（§3.2）。
@MainActor
struct FooterView: View {
    let updatedText: String
    let connectionCount: Int
    let onRefresh: () -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            Text(updatedText)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)

            IconButtonView(systemName: "arrow.clockwise", label: "刷新订阅", iconSize: 11) {
                onRefresh()
            }

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                IconButtonView(systemName: "link", label: "连接列表", iconSize: 13) {
                    PlaceholderPanel.show(
                        title: "连接列表",
                        detail: "连接列表与规则命中详情未实现，这里只验证入口。"
                    )
                }
                Text("\(connectionCount)")
                    .font(Typography.number)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.trailing, 4)
                    .accessibilityLabel(Text("连接数 \(connectionCount)"))
            }

            IconButtonView(systemName: "text.alignleft", label: "日志", iconSize: 12) {
                PlaceholderPanel.show(
                    title: "日志",
                    detail: "日志窗口未实现。真实版本会在这里展示内核输出。"
                )
            }

            IconButtonView(systemName: "gearshape", label: "设置", iconSize: 12) {
                openWindow(id: DemoWindowID.demo)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .frame(height: Metrics.footerHeight)
    }
}
