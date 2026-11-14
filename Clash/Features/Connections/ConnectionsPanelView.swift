import SwiftUI

/// 二级面板：活动连接（`GET /connections`）。同宽同高推入，复用 §4.7 的推入 / 面包屑规范。
///
/// 面包屑右侧是「全部关闭」（仅当有连接时出现）；底栏左条数、右总量。
/// 面板出现时开始 2s 轮询，消失即停。
@MainActor
struct ConnectionsPanelView: View {
    let model: PanelPreviewModel
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb

            if let error = model.connectionsError {
                noticeRow(error)
                    .padding(.top, Space.xs)
            }

            content

            footer
        }
        .frame(
            width: Metrics.panelWidth - Metrics.panelPadding * 2,
            height: Metrics.panelHeight - Metrics.panelPadding * 2
        )
        .onAppear { model.startConnectionPolling() }
        .onDisappear { model.stopConnectionPolling() }
    }

    // MARK: - 面包屑

    private var breadcrumb: some View {
        HStack(spacing: Space.xs) {
            IconButtonView(systemName: "chevron.left", label: "返回", iconSize: 12) {
                onBack()
            }

            Text("连接")
                .font(Typography.pageTitle)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: Space.s)

            if model.connectionCount > 0 {
                TextActionButton(title: "全部关闭") {
                    model.closeAllConnections()
                }
                .accessibilityHint(Text("关闭列表中的全部连接"))
            }
        }
        .frame(height: Metrics.breadcrumbHeight)
    }

    // MARK: - 列表 / 空态

    @ViewBuilder
    private var content: some View {
        if model.connectionEntries.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(model.connectionEntries) { entry in
                        ConnectionRowView(entry: entry) {
                            model.closeConnection(id: entry.id)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "link")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)

            Text("没有活动连接")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// 失败不静默（§7）：挂在面包屑下，不挤占底栏
    private func noticeRow(_ text: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.warning)

            Text(text)
                .font(Typography.caption)
                .foregroundStyle(Theme.warning)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: Space.s) {
            Text("共 \(model.connectionCount) 条")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: Space.s)

            Text(totalsText)
                .font(Typography.number)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel(Text(totalsAccessibilityLabel))
        }
        .frame(height: Metrics.footerHeight)
    }

    private var totalsText: String {
        "↑ \(TrafficFormat.bytes(model.connectionsTotalUp)) ↓ \(TrafficFormat.bytes(model.connectionsTotalDown))"
    }

    private var totalsAccessibilityLabel: String {
        "上传总量 \(TrafficFormat.spokenBytes(model.connectionsTotalUp))，"
            + "下载总量 \(TrafficFormat.spokenBytes(model.connectionsTotalDown))"
    }
}

/// 面包屑右侧的文字按钮：`text/secondary` → hover `text/primary`，无底、28pt 热区。
@MainActor
private struct TextActionButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, Space.m)
                .frame(height: Metrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .accessibilityLabel(Text(title))
    }
}
