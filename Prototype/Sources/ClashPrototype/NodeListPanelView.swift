import SwiftUI

/// 二级面板：同宽同高，只替换中间区域；面包屑返回 + 批量测速（§4.7）。
/// 面包屑与底栏都不画线。
@MainActor
struct NodeListPanelView: View {
    let model: PrototypeModel
    let group: DemoGroup
    let onBack: () -> Void

    private var isTesting: Bool { model.isSpeedTesting(group.id) }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(group.nodes) { node in
                        NodeRowView(
                            node: node,
                            isSelected: group.isSelected(node),
                            isAvailable: node.latency != nil,
                            isTesting: isTesting,
                            rowHeight: 44,
                            pillInsetV: Metrics.listPillInsetV,
                            action: { model.selectNode(groupID: group.id, nodeID: node.id) }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)

            footer
        }
        .frame(
            width: Metrics.panelWidth - Metrics.panelPadding * 2,
            height: Metrics.panelHeight - Metrics.panelPadding * 2
        )
    }

    private var breadcrumb: some View {
        HStack(spacing: 2) {
            IconButtonView(systemName: "chevron.left", label: "返回", iconSize: 12) {
                onBack()
            }

            Text(group.name)
                .font(Typography.title)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 6)

            speedButton
        }
        .frame(height: Metrics.cardHeaderHeight)
    }

    @ViewBuilder
    private var speedButton: some View {
        if isTesting {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 28, height: 28)
                .padding(.trailing, 4)
                .accessibilityLabel("测速中")
        } else {
            IconButtonView(systemName: "speedometer", label: "测速全部节点", iconSize: 16) {
                model.testAllNodes(in: group.id)
            }
            .padding(.trailing, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
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

            Spacer(minLength: 6)

            Text("右键菜单未实现")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(height: Metrics.footerHeight)
    }
}
