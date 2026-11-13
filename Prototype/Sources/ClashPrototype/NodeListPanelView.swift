import SwiftUI

/// 二级面板：同宽同高，只替换中间区域；面包屑返回（§4.7）。
@MainActor
struct NodeListPanelView: View {
    let model: PrototypeModel
    let group: DemoGroup
    let onBack: () -> Void

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

            Text(group.selectedNode?.name ?? "")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .padding(.trailing, 4)
        }
        .frame(height: Metrics.cardHeaderHeight)
        .overlay(alignment: .bottom) { HairlineView() }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("共 \(group.nodes.count) 个节点")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: 6)

            Text("右键菜单未实现")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(height: Metrics.footerHeight)
        .overlay(alignment: .top) { HairlineView() }
    }
}
