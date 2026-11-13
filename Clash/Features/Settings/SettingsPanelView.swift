import AppKit
import SwiftUI

/// 二级面板：设置（`docs/02-UI-SPEC.md` §4.9）。
///
/// 与「策略组详情」「订阅管理」一样推入：同宽 340、面包屑返回、内容可滚动（隐藏滚动条）、
/// 无底栏、底部留 12pt。三段：**代理 / 订阅 / 组件与维护**——行高 32，label 左、控件右，
/// 分组靠 16pt 间距与 11pt 小标题区分，**不画横线**。
///
/// 每次改动立即落盘（`SettingsStore` 原子写），写失败在页内显示红字，不静默。
/// 只保留必要的系统弹窗：授权密码框、`NSOpenPanel`、完全清理 / 卸载组件的破坏性确认。
@MainActor
struct SettingsPanelView: View {
    let model: PanelPreviewModel
    let settings: SettingsStore
    let onBack: () -> Void

    @State private var portText: String
    @State private var uaChoice: UserAgentChoice
    @State private var loginNotice: String?
    @State private var maintenanceNotice: String?
    @State private var maintenanceFailed = false
    @State private var isCleaningUp = false
    @State private var showsCleanupConfirmation = false
    @State private var showsUninstallConfirmation = false
    @State private var helper: HelperComponentModel

    init(model: PanelPreviewModel, settings: SettingsStore, onBack: @escaping () -> Void) {
        self.model = model
        self.settings = settings
        self.onBack = onBack
        _portText = State(initialValue: String(settings.mixedPort))
        _uaChoice = State(initialValue: UserAgentChoice.resolve(from: settings.subscriptionUserAgent))
        _helper = State(initialValue: HelperComponentModel(tun: model.tun))
    }

    private var contentWidth: CGFloat { Metrics.panelWidth - Metrics.panelPadding * 2 }
    private var contentHeight: CGFloat { Metrics.panelHeight - Metrics.panelPadding * 2 }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb

            if model.needsKernelRestartForSettings {
                restartRow
                    .padding(.top, Metrics.bannerSpacing)
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    proxySection
                    subscriptionSection
                    componentSection

                    if let error = settings.lastError {
                        noticeText(error, isError: true)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: contentWidth, height: contentHeight)
        .onAppear {
            syncLoginItemState()
            Task { await helper.refresh() }
        }
        // 破坏性确认属于「必要的弹窗」：清理不可撤销，点错一次要丢全部本地数据
        .alert("完全清理？", isPresented: $showsCleanupConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) { runCleanup() }
        } message: {
            Text("将还原系统代理、停止内核，并删除订阅配置、运行配置、内核数据、日志与代理快照。App 本身与设置会保留。此操作不可撤销。")
        }
    }

    // MARK: - 面包屑

    private var breadcrumb: some View {
        HStack(spacing: 2) {
            IconButtonView(systemName: "chevron.left", label: "返回", iconSize: 12) {
                onBack()
            }

            Text("设置")
                .font(Typography.title)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 6)
        }
        .frame(height: Metrics.cardHeaderHeight)
    }

    /// 端口 / 局域网 / 日志级别已改，内核还用旧值：页内一条提示行，不弹窗
    private var restartRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.warning)

            Text("需要重启内核生效")
                .font(Typography.caption)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 6)

            if model.isApplyingSettings {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Button("立即重启") { model.restartKernelForSettings() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                .fill(Theme.warning.opacity(0.14))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 段一：代理

    private var proxySection: some View {
        section("代理") {
            VStack(alignment: .leading, spacing: 2) {
                row("混合端口") {
                    TextField("7890", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(Typography.number)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(isPortValid ? Theme.textPrimary : Theme.error)
                        .frame(width: 64)
                        .overlay {
                            if !isPortValid {
                                RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                                    .strokeBorder(Theme.error, lineWidth: 1)
                            }
                        }
                        .onChange(of: portText) { _, text in applyPort(text) }
                        .accessibilityLabel(Text("混合端口"))
                }

                if !isPortValid {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Text("1024–65535")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.error)
                    }
                }
            }

            row("允许局域网") {
                Toggle("", isOn: Binding(
                    get: { settings.allowLAN },
                    set: { settings.allowLAN = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(Text("允许局域网访问"))
                .accessibilityHint(Text("开启后同一局域网的设备可经这台电脑代理；控制端口仍只监听本机"))
            }

            row("关闭代理时保留内核") {
                Toggle("", isOn: Binding(
                    get: { settings.keepKernelOnProxyOff },
                    set: { settings.keepKernelOnProxyOff = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(Text("关闭代理时保留内核"))
                .accessibilityHint(Text("关闭后关代理会一并停止内核；保留时仍可挑选节点与测速"))
            }
        }
    }

    // MARK: - 段二：订阅

    private var subscriptionSection: some View {
        section("订阅") {
            row("User-Agent") {
                Menu {
                    ForEach(UserAgentChoice.allCases) { choice in
                        Button(choice.title) { applyUAChoice(choice) }
                    }
                } label: {
                    menuLabel(uaChoice.title)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("订阅 User-Agent"))
            }

            if uaChoice == .custom {
                TextField(customUAPlaceholder, text: Binding(
                    get: { settings.subscriptionUserAgent },
                    set: { settings.subscriptionUserAgent = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 11))
                .accessibilityLabel(Text("自定义 User-Agent"))
            }

            row("默认更新间隔") {
                Menu {
                    ForEach(SettingsStore.autoUpdateOptions, id: \.self) { hours in
                        Button(autoUpdateTitle(hours)) { settings.autoUpdateHours = hours }
                    }
                } label: {
                    menuLabel(autoUpdateTitle(settings.autoUpdateHours))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("默认更新间隔"))
            }
        }
    }

    private var customUAPlaceholder: String {
        "留空使用 mihomo/\(SubscriptionUserAgent.bundledKernelVersion)"
    }

    private func autoUpdateTitle(_ hours: Int) -> String {
        hours == 0 ? "手动" : "\(hours) 小时"
    }

    // MARK: - 段三：组件与维护

    private var componentSection: some View {
        section("组件与维护") {
            VStack(alignment: .leading, spacing: 2) {
                // 状态点 + 文案 + 右侧小按钮：四态（未安装 / 已安装 / 需要更新 / 未运行）互斥
                HStack(spacing: 6) {
                    Circle()
                        .fill(helperStatusColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)

                    Text(helper.statusText)
                        .font(Typography.body)
                        .foregroundStyle(helper.isStatusWarning ? Theme.warning : Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 6)

                    if helper.isWorking {
                        ProgressView()
                            .controlSize(.mini)
                    } else if let action = helper.action {
                        Button(action.title) { handleHelperAction(action) }
                            .controlSize(.small)
                    }
                }
                .frame(height: Metrics.rowHeight)

                Text(helper.hintText)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let notice = helper.notice {
                    noticeText(notice, isError: helper.noticeIsError)
                }
            }
            .alert("卸载特权组件？", isPresented: $showsUninstallConfirmation) {
                Button("取消", role: .cancel) {}
                Button("卸载", role: .destructive) { Task { await helper.perform() } }
            } message: {
                Text("将停止 TUN、移除管理员组件；系统代理与订阅不受影响。")
            }

            VStack(alignment: .leading, spacing: 2) {
                row("开机自启") {
                    Toggle("", isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel(Text("开机自启"))
                    .accessibilityHint(Text("随登录自动启动；本地签名的构建可能被系统拒绝"))
                }

                if let loginNotice {
                    noticeText(loginNotice, isError: loginNotice.contains("失败"))
                }
            }

            row("日志级别") {
                Menu {
                    ForEach(LogLevelSetting.allCases) { level in
                        Button(level.title) { settings.logLevel = level }
                    }
                } label: {
                    menuLabel(settings.logLevel.title)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("日志级别"))
            }

            HStack(spacing: 8) {
                Button("打开配置目录") {
                    NSWorkspace.shared.open(AppPaths.supportDirectory)
                }
                .controlSize(.small)

                Button("打开日志目录") {
                    NSWorkspace.shared.open(AppPaths.logsDirectory)
                }
                .controlSize(.small)

                Spacer(minLength: 4)

                if isCleaningUp {
                    ProgressView()
                        .controlSize(.mini)
                }

                Button {
                    showsCleanupConfirmation = true
                } label: {
                    Text("完全清理…")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.error)
                }
                .buttonStyle(.borderless)
                .disabled(isCleaningUp)
                .accessibilityHint(Text("还原系统代理、停止内核并删除本地数据，App 本身保留"))
            }
            .frame(height: Metrics.rowHeight)

            if let maintenanceNotice {
                noticeText(maintenanceNotice, isError: maintenanceFailed)
            }
        }
    }

    private var helperStatusColor: Color {
        switch helper.state {
        case .installed: Theme.success
        case .needsUpdate, .installedNotRunning: Theme.warning
        case .checking, .notInstalled: Theme.textTertiary
        }
    }

    /// 卸载要二次确认（会停 TUN）；安装 / 更新 / 重新安装直接走一次系统授权
    private func handleHelperAction(_ action: HelperComponentModel.Action) {
        if action == .uninstall {
            showsUninstallConfirmation = true
        } else {
            Task { await helper.perform() }
        }
    }

    // MARK: - 通用部件

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Typography.section)
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 2)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 32pt 行：label 左、控件右
    private func row<Content: View>(
        _ title: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            control()
        }
        .frame(height: Metrics.rowHeight)
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 2) {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func noticeText(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(isError ? Theme.error : Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 端口

    private var isPortValid: Bool {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)) else { return false }
        return SettingsStore.portRange.contains(value)
    }

    private func applyPort(_ text: String) {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)),
              SettingsStore.portRange.contains(value) else { return }
        settings.mixedPort = value
    }

    // MARK: - UA

    private func applyUAChoice(_ choice: UserAgentChoice) {
        switch choice {
        case .systemDefault:
            settings.subscriptionUserAgent = ""
        case .clashVerge:
            settings.subscriptionUserAgent = SubscriptionUserAgent.presets[0]
        case .clashMeta:
            settings.subscriptionUserAgent = SubscriptionUserAgent.presets[1]
        case .custom:
            // 从预设切到自定义：清空成空白框；已经是自定义则保留用户输入
            if UserAgentChoice.resolve(from: settings.subscriptionUserAgent) != .custom {
                settings.subscriptionUserAgent = ""
            }
        }
    }

    // MARK: - 开机自启

    /// 系统状态是唯一真相：已启用就同步到设置，未启用不覆盖用户偏好
    private func syncLoginItemState() {
        if LaunchAtLogin.isEnabled, !settings.launchAtLogin {
            settings.launchAtLogin = true
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            settings.launchAtLogin = enabled
            let status = LaunchAtLogin.statusText
            if LaunchAtLogin.isEnabled {
                loginNotice = "登录项：\(status)"
            } else {
                loginNotice = "已提交，登录项：\(status)。\(LaunchAtLogin.failureHint)"
            }
        } catch {
            settings.launchAtLogin = LaunchAtLogin.isEnabled
            loginNotice = "开机自启设置失败：\(error.localizedDescription)。\(LaunchAtLogin.failureHint)"
        }
    }

    // MARK: - 完全清理

    private func runCleanup() {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        Task {
            let error = await model.performFullCleanup()
            isCleaningUp = false
            maintenanceFailed = error != nil
            maintenanceNotice = error ?? "已清理，订阅与内核数据已删除"
        }
    }
}

/// UA 选项：与 ADR-0006 的三个预设 + 自定义一一对应（空串 = 默认 `mihomo/<版本>`）。
///
/// 面板只有 340 宽，菜单标题取短名；完整 UA 串在自定义输入框的占位文案里给出。
enum UserAgentChoice: String, CaseIterable, Identifiable, Hashable {
    case systemDefault
    case clashVerge
    case clashMeta
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemDefault: "默认"
        case .clashVerge: "clash-verge"
        case .clashMeta: "ClashMetaForAndroid"
        case .custom: "自定义"
        }
    }

    static func resolve(from value: String) -> UserAgentChoice {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .systemDefault }
        if trimmed == SubscriptionUserAgent.presets[0] { return .clashVerge }
        if trimmed == SubscriptionUserAgent.presets[1] { return .clashMeta }
        return .custom
    }
}

#if DEBUG
#Preview("设置页") {
    let settings = SettingsStore(fileURL: URL.temporaryDirectory.appending(path: "clash-preview-settings.json"))
    SettingsPanelView(
        model: PanelPreviewModel(settings: settings, autoStartsKernel: false),
        settings: settings,
        onBack: {}
    )
}
#endif
