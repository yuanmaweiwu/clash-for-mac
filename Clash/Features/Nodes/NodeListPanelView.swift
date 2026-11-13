import SwiftUI

/// 二级面板：同宽同高，只替换中间区域；面包屑返回 + 批量测速（§4.7）。
/// 面包屑与底栏都不画线。
@MainActor
struct NodeListPanelView: View {
    let model: PanelPreviewModel
    let group: ProxyGroupModel
    let onBack: () -> Void

    private var isTesting: Bool { model.isSpeedTesting(group.id) }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(group.nodesSortedByLatency) { node in
                        NodeRowView(
                            node: node,
                            isSelected: group.isSelected(node),
                            isAvailable: node.isAvailable,
                            isTesting: isTesting,
                            rowHeight: Metrics.listRowHeight,
                            pillInsetV: Metrics.listPillInsetV,
                            action: { model.selectNode(groupID: group.id, nodeID: node.id) }
                        )
                    }
                }
                .id(group.listOrderKey)
                .transition(.opacity)
            }
            .scrollIndicators(.never)
            .allowsHitTesting(!isTesting)
            .animation(.easeInOut(duration: 0.18), value: group.listOrderKey)

            footer
        }
        .frame(
            width: Metrics.panelWidth - Metrics.panelPadding * 2,
            height: Metrics.panelHeight - Metrics.panelPadding * 2
        )
    }

    private var breadcrumb: some View {
        HStack(spacing: Space.xs) {
            IconButtonView(systemName: "chevron.left", label: "返回", iconSize: 12) {
                onBack()
            }

            Text(group.name)
                .font(Typography.pageTitle)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: Space.s)

            speedButton
        }
        .frame(height: Metrics.breadcrumbHeight)
    }

    @ViewBuilder
    private var speedButton: some View {
        if isTesting {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 28, height: 28)
                .padding(.trailing, Space.xs)
                .allowsHitTesting(false)
                .accessibilityLabel("测速中")
        } else {
            IconButtonView(systemName: "speedometer", label: "测速全部节点", iconSize: 16) {
                model.testAllNodes(in: group.id)
            }
            .padding(.trailing, Space.xs)
        }
    }

    private var footer: some View {
        HStack(spacing: Space.s) {
            if let notice = model.speedNotice {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.warning)
                Text(notice)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.warning)
            } else {
                Text("共 \(group.nodes.count) 个节点")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: Space.s)

            if isTesting {
                Text("测速中…")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .transition(.opacity)
            } else if model.speedResultFlash {
                Text("刚刚更新")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .transition(.opacity)
            }
        }
        .frame(height: Metrics.footerHeight)
        .animation(.easeInOut(duration: 0.2), value: isTesting)
        .animation(.easeInOut(duration: 0.2), value: model.speedResultFlash)
    }
}
