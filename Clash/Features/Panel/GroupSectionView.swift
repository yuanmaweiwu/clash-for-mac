import SwiftUI

/// 分组区：只显示被 pin 的组；1 张卡时 148pt、2 张卡时 286pt（§3.4）。
/// banner 出现时高度被压缩，内容仍在，靠这里滚动查看（§3.5）。
@MainActor
struct GroupSectionView: View {
    let model: PanelPreviewModel

    var body: some View {
        Group {
            if model.groups.isEmpty {
                EmptyGroupView(
                    title: model.emptyGroupTitle,
                    showsImportActions: model.showsEmptyGroupImportActions
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        GroupSectionHeaderView {
                            model.openAllGroups()
                        }

                        ForEach(Array(model.pinnedGroups.enumerated()), id: \.element.id) { index, group in
                            GroupCardView(
                                group: group,
                                onOpen: { model.pushGroup(group.id) },
                                onSelect: { nodeID in
                                    model.selectNode(groupID: group.id, nodeID: nodeID)
                                }
                            )
                            .padding(.top, index == 0 ? 0 : Metrics.tileGap)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(height: model.groupSectionHeight, alignment: .top)
        .clipped()
    }
}
