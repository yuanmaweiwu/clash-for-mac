import SwiftUI

/// 二级面板：订阅管理（§4.8）。由订阅磁贴推入，同宽同高。
@MainActor
struct SubscriptionPanelView: View {
    let model: PrototypeModel
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb

            if let notice = model.subscriptionNotice {
                SubscriptionNoticeView(text: notice)
                    .padding(.top, 8)
            }

            if model.subscriptions.isEmpty {
                EmptySubscriptionView(
                    onImportURL: { showURLImport() },
                    onImportYAML: { model.addLocalSubscription() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.subscriptions.enumerated()), id: \.element.id) { index, profile in
                            SubscriptionRowView(
                                profile: profile,
                                isActive: profile.id == model.activeSubscriptionID,
                                isUpdating: profile.id == model.updatingSubscriptionID,
                                onActivate: { model.activateSubscription(profile.id) },
                                onUpdate: { model.updateSubscription(profile.id) },
                                onRename: {
                                    SubscriptionEditPanel.show(mode: .rename(current: profile.name)) { name in
                                        model.renameSubscription(profile.id, to: name)
                                    }
                                },
                                onDelete: { model.deleteSubscription(profile.id) },
                                forcedHover: model.debugHoverSubscriptionIndex == index
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)

                footer
            }
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

            Text("订阅")
                .font(Typography.title)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 6)

            Menu {
                Button("导入订阅…") { showURLImport() }
                Button("选择 YAML…") { model.addLocalSubscription() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("添加订阅"))
        }
        .frame(height: Metrics.cardHeaderHeight)
        .overlay(alignment: .bottom) { HairlineView() }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("共 \(model.subscriptions.count) 条订阅")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: 6)

            if let active = model.activeSubscription {
                Text("当前激活 \(active.name)")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(height: Metrics.footerHeight)
        .overlay(alignment: .top) { HairlineView() }
    }

    private func showURLImport() {
        SubscriptionEditPanel.show(mode: .url) { url in
            model.addSubscription(url: url)
        }
    }
}
