import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 二级面板：添加订阅（`docs/02-UI-SPEC.md` §4.10）。由订阅页 `＋` 推入，同宽 340。
///
/// 只有一条输入框与两个入口：URL 导入走内核校验，本地 YAML 走 `NSOpenPanel`。
/// **失败不弹 alert**——红字留在输入框下方；成功后由模型退回订阅列表并高亮新项。
@MainActor
struct SubscriptionNewPanelView: View {
    let model: PanelPreviewModel
    let onBack: () -> Void

    @State private var urlText = ""

    private var contentWidth: CGFloat { Metrics.panelWidth - Metrics.panelPadding * 2 }
    private var contentHeight: CGFloat { Metrics.panelHeight - Metrics.panelPadding * 2 }

    private var trimmed: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumb

            VStack(alignment: .leading, spacing: Space.l) {
                PanelTextField(
                    "订阅链接（https://…）",
                    text: $urlText,
                    label: "订阅链接",
                    isAutofocused: true
                )
                .disabled(model.isImportingProfile)
                .onSubmit { submit() }

                if let error = model.importError {
                    Text(error)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("导入前会用内核校验；失败不会覆盖已有配置")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)

                actions
                    .padding(.top, Space.xs)
            }
            .padding(.top, Metrics.sectionGap)

            Spacer(minLength: 0)
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
    }

    // MARK: - 面包屑

    private var breadcrumb: some View {
        HStack(spacing: Space.xs) {
            IconButtonView(systemName: "chevron.left", label: "返回", iconSize: 12) {
                onBack()
            }

            Text("添加订阅")
                .font(Typography.pageTitle)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: Space.s)
        }
        .frame(height: Metrics.breadcrumbHeight)
    }

    // MARK: - 动作

    @ViewBuilder
    private var actions: some View {
        if model.isImportingProfile {
            HStack(spacing: Space.s) {
                ProgressView()
                    .controlSize(.mini)

                Text("正在获取…")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(height: Metrics.hitTarget)
            .accessibilityElement(children: .combine)
        } else {
            Button("导入") { submit() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(trimmed.isEmpty)
                .frame(height: Metrics.hitTarget)
        }
    }

    private func submit() {
        guard !trimmed.isEmpty, !model.isImportingProfile else { return }
        model.importSubscription(urlString: trimmed)
    }


}
