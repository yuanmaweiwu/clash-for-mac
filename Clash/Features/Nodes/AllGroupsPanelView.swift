import SwiftUI

/// 二级面板：全部策略组，点行切换首屏展示的那**一个**组（单选，不选节点；§3.4 / §4.7）。
@MainActor
struct AllGroupsPanelView: View {
    let model: PanelPreviewModel
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.allGroups.enumerated()), id: \.element.id) { _, group in
                        AllGroupsRowView(
                            group: group,
                            isSelected: group.id == model.displayedGroupID,
                            showsInactiveLabel: model.showsInactiveLabel(for: group),
                            onSelect: { model.display(groupID: group.id) }
                        )
                    }
                }
            }
            .scrollIndicators(.never)

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

            Text("全部策略组")
                .font(Typography.pageTitle)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: Space.s)
        }
        .frame(height: Metrics.breadcrumbHeight)
    }

    private var footer: some View {
        HStack(spacing: Space.s) {
            Text("共 \(model.allGroups.count) 个策略组")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: Space.s)

            Text("点行切换展示的策略组")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(height: Metrics.footerHeight)
    }
}
