import SwiftUI

/// 二级面板：全部策略组，右侧星标控制是否固定到首屏（§3.4）。
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
                            isActive: group.id == model.activeGroupID,
                            onTogglePin: { model.togglePin(group.id) },
                            onOpen: { model.pushGroup(group.id) }
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

            Text("全部策略组")
                .font(Typography.title)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 6)
        }
        .frame(height: Metrics.cardHeaderHeight)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("共 \(model.allGroups.count) 个策略组")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: 6)

            Text("星标固定到首屏")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(height: Metrics.footerHeight)
    }
}
