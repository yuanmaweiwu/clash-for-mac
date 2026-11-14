import SwiftUI

/// 分组区：只显示**一张**卡——当前展示组（单选），按内容自然高度排（§3.4）。
/// 没被规则引用的组照常显示，只由卡片头加「未生效」提示；换组走「全部 ›」。
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

                    if let group = model.displayedGroup {
                        GroupCardView(
                            group: group,
                            showsInactiveLabel: model.showsInactiveLabel(for: group),
                            onOpen: { model.pushGroup(group.id) },
                            onSelect: { nodeID in
                                model.selectNode(groupID: group.id, nodeID: nodeID)
                            }
                        )
                    }
                }
            }
        }
        .frame(height: model.groupSectionContentHeight, alignment: .top)
    }
}
