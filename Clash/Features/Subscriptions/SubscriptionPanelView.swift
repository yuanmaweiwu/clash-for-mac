import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 二级面板：订阅管理（§4.8）。由订阅磁贴推入，同宽同高。
@MainActor
struct SubscriptionPanelView: View {
    let model: PanelPreviewModel
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb

            if let notice = model.subscriptionNotice {
                SubscriptionNoticeView(text: notice)
                    .padding(.top, 8)
            }

            switch model.subscriptionPanelState {
            case .loading:
                SubscriptionStateView(kind: .loading)
            case .failed(let message):
                SubscriptionStateView(kind: .failed(message)) {
                    model.retrySubscriptions()
                }
            case .loaded:
                subscriptionList
            }
        }
        .frame(
            width: Metrics.panelWidth - Metrics.panelPadding * 2,
            height: Metrics.panelHeight - Metrics.panelPadding * 2
        )
    }

    /// 已加载：空库 → 占位卡；有条目 → 列表 + 底部说明
    @ViewBuilder
    private var subscriptionList: some View {
        if model.subscriptions.isEmpty {
            EmptySubscriptionView(
                onImportURL: { model.openSubscriptionNewPage() },
                onImportYAML: { chooseYAMLFile() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.subscriptions) { profile in
                            SubscriptionRowView(
                                profile: profile,
                                isActive: profile.id == model.activeSubscriptionID,
                                isHighlighted: profile.id == model.recentlyImportedProfileID,
                                isUpdating: profile.id == model.updatingProfileID,
                                onActivate: { model.activateSubscription(profile.id) },
                                onUpdate: { model.updateSubscription(profile.id) },
                                onRename: {
                                    SubscriptionEditPanel.showRename(current: profile.name) { name in
                                        model.renameSubscription(profile.id, to: name)
                                    }
                                },
                                onCopyLink: { copyLink(of: profile) },
                                onDelete: { model.deleteSubscription(profile.id) }
                            )
                            .id(profile.id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    // 导入成功时页面才被推回来：那时 `onChange` 已经错过，这里补一次定位
                    guard let id = model.recentlyImportedProfileID else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
                .onChange(of: model.recentlyImportedProfileID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            footer
        }
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

            IconButtonView(systemName: "plus", label: "添加订阅", iconSize: 12) {
                model.openSubscriptionNewPage()
            }
        }
        .frame(height: Metrics.cardHeaderHeight)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("共 \(model.subscriptions.count) 条订阅")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: 6)

            if let active = model.activeSubscription {
                Text(isUpdating(active) ? "正在更新「\(active.name)」" : "当前激活 \(active.name)")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(height: Metrics.footerHeight)
    }

    private func isUpdating(_ profile: ProfileEntry) -> Bool {
        profile.id == model.updatingProfileID
    }

    /// `NSOpenPanel` 只在 UI 层做；store 只接收 fileURL
    private func chooseYAMLFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 YAML 配置"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = ["yaml", "yml"].compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importLocalSubscription(fileURL: url)
    }

    private func copyLink(of profile: ProfileEntry) {
        guard let link = profile.source.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }
}
