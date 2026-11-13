import AppKit
import SwiftUI

/// 设置窗口（独立 `Window`，单例）：四组「代理 / 订阅 / 启动与日志 / 维护」。
///
/// 规范：`docs/02-UI-SPEC.md` §2（token）、§8.7（设置窗口独立且不承载日常操作）。
/// 组间 20pt、组内行 32pt、**不画横线**，靠留白分组；文字用语义字号，支持 Dynamic Type。
/// 每次改动立即落盘（`SettingsStore` 原子写），写失败在底部显示红色提示，不静默。
@MainActor
struct SettingsWindowView: View {
    let model: PanelPreviewModel
    let settings: SettingsStore

    @State private var portText: String
    @State private var uaChoice: UserAgentChoice
    @State private var loginNotice: String?
    @State private var maintenanceNotice: String?
    @State private var maintenanceFailed = false
    @State private var isCleaningUp = false
    @State private var showsCleanupConfirmation = false

    init(model: PanelPreviewModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings
        let initialChoice = UserAgentChoice.resolve(from: settings.subscriptionUserAgent)
        _portText = State(initialValue: String(settings.mixedPort))
        _uaChoice = State(initialValue: initialChoice)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                proxySection
                subscriptionSection
                startupSection
                maintenanceSection

                if let error = settings.lastError {
                    noticeText(error, isError: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 460)
        .onAppear { syncLoginItemState() }
        .alert("完全清理？", isPresented: $showsCleanupConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) { runCleanup() }
        } message: {
            Text("将还原系统代理、停止内核，并删除订阅配置、运行配置、内核数据、日志与代理快照。App 本身与设置会保留。此操作不可撤销。")
        }
    }

    // MARK: - 代理

    private var proxySection: some View {
        section("代理") {
            portRow

            Toggle("允许局域网访问", isOn: Binding(
                get: { settings.allowLAN },
                set: { settings.allowLAN = $0 }
            ))
            .toggleStyle(.switch)
            .frame(minHeight: 32)
            .accessibilityHint(Text("开启后同一局域网的设备可经这台电脑代理；控制端口仍只监听本机"))

            Toggle("关闭代理时保留内核", isOn: Binding(
                get: { settings.keepKernelOnProxyOff },
                set: { settings.keepKernelOnProxyOff = $0 }
            ))
            .toggleStyle(.switch)
            .frame(minHeight: 32)
            .accessibilityHint(Text("关闭后关代理会一并停止内核；保留时仍可挑选节点与测速"))

            if model.needsKernelRestartForSettings {
                restartNotice
            }
        }
    }

    private var portRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent {
                TextField("7890", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(isPortValid ? Theme.textPrimary : Theme.error)
                    .frame(width: 96)
                    .overlay {
                        if !isPortValid {
                            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                                .strokeBorder(Theme.error, lineWidth: 1)
                        }
                    }
                    .onChange(of: portText) { _, text in applyPort(text) }
                    .accessibilityLabel(Text("混合端口"))
            } label: {
                settingLabel("混合端口")
            }
            .frame(minHeight: 32)

            if !isPortValid {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text("1024–65535")
                        .font(.caption)
                        .foregroundStyle(Theme.error)
                }
            }
        }
    }

    private var restartNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.warning)

            Text(restartNoticeText)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            if model.isApplyingSettings {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("立即重启") { model.restartKernelForSettings() }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var restartNoticeText: String {
        if model.kernelActiveMixedPort != settings.mixedPort {
            return "端口已改为 \(settings.mixedPort)，需要重启内核生效"
        }
        if model.kernelActiveAllowLAN != settings.allowLAN {
            return "局域网访问已改为「\(settings.allowLAN ? "允许" : "禁止")」，需要重启内核生效"
        }
        return "日志级别已改为「\(settings.logLevel.title)」，需要重启内核生效"
    }

    // MARK: - 订阅

    private var subscriptionSection: some View {
        section("订阅") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent {
                    Picker("", selection: $uaChoice) {
                        ForEach(UserAgentChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: uaChoice) { _, choice in applyUAChoice(choice) }
                    .accessibilityLabel(Text("订阅 User-Agent"))
                } label: {
                    settingLabel("User-Agent")
                }
                .frame(minHeight: 32)

                if uaChoice == .custom {
                    TextField(customUAPlaceholder, text: Binding(
                        get: { settings.subscriptionUserAgent },
                        set: { settings.subscriptionUserAgent = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                }

                Text("UA 只用于拉取订阅；被拒时自动换默认 UA 重试一次")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            LabeledContent {
                Picker("", selection: Binding(
                    get: { settings.autoUpdateHours },
                    set: { settings.autoUpdateHours = $0 }
                )) {
                    ForEach(SettingsStore.autoUpdateOptions, id: \.self) { hours in
                        Text(autoUpdateTitle(hours)).tag(hours)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .accessibilityLabel(Text("默认更新间隔"))
            } label: {
                settingLabel("默认更新间隔")
            }
            .frame(minHeight: 32)
        }
    }

    private var customUAPlaceholder: String {
        "留空使用 mihomo/\(SubscriptionUserAgent.bundledKernelVersion)"
    }

    private func autoUpdateTitle(_ hours: Int) -> String {
        hours == 0 ? "手动" : "\(hours) 小时"
    }

    // MARK: - 启动与日志

    private var startupSection: some View {
        section("启动与日志") {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("开机自启", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .frame(minHeight: 32)
                .accessibilityHint(Text("随登录自动启动；本地签名的构建可能被系统拒绝"))

                if let loginNotice {
                    noticeText(loginNotice, isError: loginNotice.contains("失败"))
                }
            }

            LabeledContent {
                Picker("", selection: Binding(
                    get: { settings.logLevel },
                    set: { settings.logLevel = $0 }
                )) {
                    ForEach(LogLevelSetting.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .accessibilityLabel(Text("日志级别"))
            } label: {
                settingLabel("日志级别")
            }
            .frame(minHeight: 32)
        }
    }

    // MARK: - 维护

    private var maintenanceSection: some View {
        section("维护") {
            HStack(spacing: 8) {
                Button("打开配置目录") {
                    NSWorkspace.shared.open(AppPaths.supportDirectory)
                }

                Button("打开日志目录") {
                    NSWorkspace.shared.open(AppPaths.logsDirectory)
                }

                Spacer(minLength: 8)

                if isCleaningUp {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    showsCleanupConfirmation = true
                } label: {
                    Text("完全清理…")
                        .foregroundStyle(Theme.error)
                }
                .buttonStyle(.borderless)
                .disabled(isCleaningUp)
                .accessibilityHint(Text("还原系统代理、停止内核并删除本地数据，App 本身保留"))
            }
            .frame(minHeight: 32)

            if let maintenanceNotice {
                noticeText(maintenanceNotice, isError: maintenanceFailed)
            }
        }
    }

    // MARK: - 通用部件

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingLabel(_ title: String) -> some View {
        Text(title)
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
    }

    private func noticeText(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(.caption)
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

/// UA 选项：与 ADR-0006 的三个预设 + 自定义一一对应（空串 = 默认 `mihomo/<版本>`）
enum UserAgentChoice: String, CaseIterable, Identifiable, Hashable {
    case systemDefault
    case clashVerge
    case clashMeta
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemDefault: "默认 mihomo/\(SubscriptionUserAgent.bundledKernelVersion)"
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
#Preview("设置窗口") {
    let settings = SettingsStore(fileURL: URL.temporaryDirectory.appending(path: "clash-preview-settings.json"))
    SettingsWindowView(
        model: PanelPreviewModel(settings: settings, autoStartsKernel: false),
        settings: settings
    )
}
#endif
