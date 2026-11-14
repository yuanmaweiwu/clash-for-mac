import SwiftUI

/// 二级面板：规则列表（`GET /rules`，§4.11）。同宽同高推入，面包屑「‹ 规则」。
///
/// 只读快照：进页面拉一次（有缓存就不拉），失败给文案 + 重试；不分组、不排序，
/// 保持内核的配置顺序——用户排查「这条为什么没命中」靠的就是顺序。
@MainActor
struct RulesPanelView: View {
    let model: PanelPreviewModel
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            content
        }
        .frame(
            width: Metrics.panelWidth - Metrics.panelPadding * 2,
            height: Metrics.panelHeight - Metrics.panelPadding * 2
        )
        .task { await model.loadRulesIfNeeded() }
    }

    // MARK: - 面包屑

    private var breadcrumb: some View {
        HStack(spacing: Space.xs) {
            IconButtonView(systemName: "chevron.left", label: "返回", iconSize: 12) {
                onBack()
            }

            Text("规则")
                .font(Typography.pageTitle)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: Space.s)

            if model.hasLoadedRules {
                Text("共 \(model.rulesCount) 条")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel(Text("共 \(model.rulesCount) 条规则"))
            }
        }
        .frame(height: Metrics.breadcrumbHeight)
    }

    // MARK: - 列表 / 三态

    @ViewBuilder
    private var content: some View {
        if let error = model.rulesError, !model.hasLoadedRules {
            failureState(error)
        } else if !model.hasLoadedRules {
            loadingState
        } else if model.rules.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.rules.enumerated()), id: \.offset) { _, rule in
                        RuleRowView(rule: rule)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var loadingState: some View {
        VStack(spacing: Space.l) {
            ProgressView()
                .controlSize(.regular)

            Text("正在读取规则…")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel(Text("正在读取规则"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)

            Text("当前配置没有规则")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: Space.l) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)

            Text("读取规则失败")
                .font(Typography.body)
                .foregroundStyle(Theme.textPrimary)

            Text(message)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.xxl + Space.xs)

            Button("重试") {
                model.refreshRules()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityHint(Text("重新读取规则列表"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
