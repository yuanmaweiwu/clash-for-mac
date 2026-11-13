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
    @FocusState private var isURLFocused: Bool

    private var contentWidth: CGFloat { Metrics.panelWidth - Metrics.panelPadding * 2 }
    private var contentHeight: CGFloat { Metrics.panelHeight - Metrics.panelPadding * 2 }

    private var trimmed: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumb

            VStack(alignment: .leading, spacing: Space.l) {
                TextField("订阅链接（https://…）", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
                    .font(Typography.body)
                    .focused($isURLFocused)
                    .disabled(model.isImportingProfile)
                    .onSubmit { submit() }
                    .accessibilityLabel(Text("订阅链接"))

                if let error = model.importError {
                    Text(error)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("导入前会用内核校验；失败不会覆盖已有配置")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)

                actions
                    .padding(.top, Space.xs)
            }
            .padding(.top, Metrics.sectionGap)

            Spacer(minLength: 0)
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
        .onAppear { isURLFocused = true }
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
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)

                Text("正在获取…")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(height: Metrics.hitTarget)
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: Space.l) {
                Button("导入") { submit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .font(.system(size: 13, weight: .medium))
                    .disabled(trimmed.isEmpty)

                Button("选择 YAML…") { chooseYAMLFile() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .font(.system(size: 13))
            }
            .frame(height: Metrics.hitTarget)
        }
    }

    private func submit() {
        guard !trimmed.isEmpty, !model.isImportingProfile else { return }
        model.importSubscription(urlString: trimmed)
    }

    /// `NSOpenPanel` 是系统必要的文件选择器：只在 UI 层做，store 只接收 fileURL
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
}
