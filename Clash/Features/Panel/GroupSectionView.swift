import SwiftUI

/// 分组区：只显示 pin 的组（最多 2 张），按内容自然高度排（§3.4）。
/// 没被规则引用的组照常显示，只由卡片头加「未生效」提示。
///
/// 滚动交给外层「网络检测 + 策略组」共用容器（`PanelView.scrollTail`），
/// 这里不再套 `ScrollView`：嵌套滚动在触控板上极易误触。
@MainActor
struct GroupSectionView: View {
    let model: PanelPreviewModel

    var body: some View {
        Group {
            if model.groups.isEmpty {
                EmptyGroupView(
                    title: model.emptyGroupTitle,
                    showsImportActions: model.showsEmptyGroupImportActions,
                    onImport: { model.openSubscriptionNewPage() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    GroupSectionHeaderView {
                        model.openAllGroups()
                    }

                    ForEach(Array(model.homeGroups.enumerated()), id: \.element.id) { index, group in
                        GroupCardView(
                            group: group,
                            showsInactiveLabel: model.showsInactiveLabel(for: group),
                            onOpen: { model.pushGroup(group.id) },
                            onSelect: { nodeID in
                                model.selectNode(groupID: group.id, nodeID: nodeID)
                            }
                        )
                        .padding(.top, index == 0 ? 0 : Space.l)
                    }
                }
            }
        }
        .frame(height: model.groupSectionContentHeight, alignment: .top)
    }
}
