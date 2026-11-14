import AppKit
import SwiftUI

/// 二级面板：设置（`docs/02-UI-SPEC.md` §4.9）。
///
/// 与「策略组详情」「订阅管理」一样推入：同宽 340、面包屑返回、内容可滚动（隐藏滚动条）、
/// 无底栏、底部留 12pt。六段：**代理 / 订阅 / 下载 / 内核 / 组件与维护 / 存储**——行高 32，label 左、
/// 控件右，分组靠 16pt 间距与 11pt 小标题区分，**不画横线**。
///
/// 设置改动持久化：下拉 / 开关立即落盘，文本字段 300ms 合并写（`SettingsStore`），
/// 写失败在页内显示红字，不静默。
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
    /// 「内核」一节：当前版本 / 检查更新 / 升级（版本只读本地文件，检查才联网）
    @State private var kernelVersion: String?
    @State private var kernelCheckState: KernelCheckState = .idle
    @State private var kernelNotice: String?
    @State private var kernelNoticeIsError = false
    /// 「存储」一节：目录清单（随组件是否安装变化）+ 各目录体积
    @State private var storageTargets: [StorageTarget] = []
    @State private var storageStates: [StorageTarget.Kind: StorageSizeState] = [:]
    @State private var isMeasuringStorage = false

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
                VStack(alignment: .leading, spacing: Space.xxl) {
                    proxySection
                    subscriptionSection
                    downloadSection
                    kernelSection
                    componentSection
                    storageSection

                    if let error = settings.lastError {
                        noticeText(error, isError: true)
                    }
                }
                .padding(.top, Metrics.sectionGap)
                .padding(.bottom, Metrics.sectionGap)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            // 底部 12pt 线性渐隐：超屏时告诉用户「下面还有内容」，不再硬切断。
            // 渐隐落在内容区 16pt 底部留白之内，滚到最底时正文不吃损。
            .mask(alignment: .bottom) { scrollFadeMask }
        }
        .frame(width: contentWidth, height: contentHeight)
        .onAppear {
            syncLoginItemState()
            model.refreshKernelVersion()
            kernelVersion = model.kernelInstalledVersion
            refreshStorageUsage()
            Task { await helper.refresh() }
        }
        // 破坏性确认属于「必要的弹窗」：清理不可撤销，点错一次要丢全部本地数据
        .alert("彻底清理？", isPresented: $showsCleanupConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) { runCleanup() }
        } message: {
            Text("将把订阅、内核、缓存与偏好移到废纸篓（可恢复），并先还原系统代理、停止内核 / TUN。已安装的特权组件需到「组件」里单独卸载；App 自身保留，完成后请重启。")
        }
    }

    // MARK: - 滚动渐隐

    /// 只给设置页用的底部遮罩：上方实体、最下 12pt 渐隐到透明。
    ///
    /// 遮罩不改命中测试，也不改内容高度；滚动到底时它覆盖的是内容区自身的 16pt 留白。
    private var scrollFadeMask: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.black)
            LinearGradient(
                colors: [.black, .black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Metrics.settingsScrollFade)
        }
    }

    // MARK: - 面包屑

    private var breadcrumb: some View {
        HStack(spacing: Space.hair) {
            IconButtonView(systemName: "chevron.left", label: "返回", iconSize: 12) {
                onBack()
            }

            Text("设置")
                .font(Typography.pageTitle)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 6)
        }
        .frame(height: Metrics.cardHeaderHeight)
    }

    /// 端口 / 局域网 / 日志级别已改，内核还用旧值：页内一条提示行，不弹窗
    private var restartRow: some View {
        HStack(spacing: Space.s) {
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
                    .controlSize(.regular)
            }
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: Metrics.rowHeight + Space.xs)
        .background {
            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                .fill(Theme.warning.opacity(0.14))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 段一：代理

    private var proxySection: some View {
        section("代理") {
            VStack(alignment: .leading, spacing: Space.m) {
                row("混合端口") {
                    PanelTextField(
                        "7890",
                        text: $portText,
                        label: "混合端口",
                        hint: "1024–65535",
                        kind: .number,
                        isInvalid: !isPortValid
                    )
                    .frame(width: 72)
                    .onChange(of: portText) { _, text in applyPort(text) }
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
                menuPicker(
                    accessibilityLabel: "订阅 User-Agent",
                    options: UserAgentChoice.allCases,
                    selection: Binding(get: { uaChoice }, set: { applyUAChoice($0) }),
                    title: { $0.title }
                )
            }

            if uaChoice == .custom {
                PanelTextField(
                    customUAPlaceholder,
                    text: Binding(
                        get: { settings.subscriptionUserAgent },
                        set: { settings.subscriptionUserAgent = $0 }
                    ),
                    label: "自定义 User-Agent"
                )
                .padding(.vertical, Space.m)
            }

            row("默认更新间隔") {
                menuPicker(
                    accessibilityLabel: "默认更新间隔",
                    options: SettingsStore.autoUpdateOptions,
                    selection: Binding(
                        get: { settings.autoUpdateHours },
                        set: { settings.autoUpdateHours = $0 }
                    ),
                    title: { autoUpdateTitle($0) }
                )
            }
        }
    }

    private var customUAPlaceholder: String {
        "留空使用 mihomo/\(SubscriptionUserAgent.bundledKernelVersion)"
    }

    private func autoUpdateTitle(_ hours: Int) -> String {
        hours == 0 ? "手动" : "\(hours) 小时"
    }

    // MARK: - 段三：下载（内核 / geodata，ADR-0012）

    private var downloadSection: some View {
        section("下载") {
            row("内核下载源") {
                menuPicker(
                    accessibilityLabel: "内核下载源",
                    options: KernelDownloadMode.allCases,
                    selection: Binding(
                        get: { settings.kernelDownloadMode },
                        set: { settings.kernelDownloadMode = $0 }
                    ),
                    title: { $0.title }
                )
            }

            if settings.kernelDownloadMode == .custom {
                PanelTextField(
                    "https://gh-proxy.com/",
                    text: Binding(
                        get: { settings.customMirrorPrefix },
                        set: { settings.customMirrorPrefix = $0 }
                    ),
                    label: "自定义下载镜像前缀",
                    hint: "镜像前缀加原始 GitHub 地址，原样拼接"
                )
                .padding(.vertical, Space.m)
            }

            Text(downloadHint)
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Space.xs)
        }
    }

    /// 镜像说明：必须写明「预置第三方镜像安全的前提是哈希校验」
    private var downloadHint: String {
        switch settings.kernelDownloadMode {
        case .automatic:
            "依次尝试：直连 → gh-proxy.com → ghproxy.net（每个约 10 秒）。"
                + "镜像只转发内容，内核仍需通过 SHA256 校验，无法被替换。"
        case .direct:
            "只走 GitHub 原始地址；不可达时请改用自动或自定义镜像。"
        case .custom:
            "前缀 + 原始 GitHub 地址，原样拼接；内核仍需通过 SHA256 校验。"
        }
    }

    // MARK: - 段四：内核（版本 / 检查更新 / 升级）

    /// 两种状态：已安装显示版本 + 「检查更新」；未安装显示「未安装」+ 「下载并安装」。
    ///
    /// 铁律（避免「先下后判」）：只有用户点按钮才发一次 GitHub API 请求；
    /// `latest == installed` 时到此为止，**不下载任何资产**（provisioner 里也只暴露了一条 API 路径）。
    private var kernelSection: some View {
        section("内核") {
            row("内核") {
                HStack(spacing: Space.s) {
                    Text(kernelVersion ?? "未安装")
                        .font(Typography.body)
                        .foregroundStyle(kernelVersion == nil ? Theme.textTertiary : Theme.textSecondary)
                        .monospacedDigit()

                    if isCheckingKernel {
                        ProgressView()
                            .controlSize(.mini)
                    } else if kernelVersion == nil {
                        Button("下载并安装") { installKernel() }
                            .controlSize(.regular)
                            .disabled(model.isUpdatingKernel)
                    } else {
                        Button("检查更新") { checkForUpdates() }
                            .controlSize(.regular)
                            .disabled(model.isUpdatingKernel)
                    }
                }
            }

            if let title = kernelUpdateTitle {
                HStack(spacing: Space.s) {
                    Text(title)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .monospacedDigit()

                    Spacer(minLength: 4)

                    if case .updateAvailable(let tag) = kernelCheckState {
                        Button("更新到 \(tag)") { startKernelUpdate(tag) }
                            .controlSize(.small)
                            .disabled(model.isUpdatingKernel)
                    }
                }
                .frame(height: Metrics.formRowHeight)
            }

            if let kernelNotice {
                noticeText(kernelNotice, isError: kernelNoticeIsError)
                    .padding(.top, Space.xs)
            }

            Text("更新只替换本机内核（~/Library/Application Support/Clash/kernel）；检查更新只问 GitHub 版本号，不下载内核。")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Space.xs)
        }
    }

    /// 第二行文案：检查中 / 已是最新 / 有新版本 / 升级中
    private var kernelUpdateTitle: String? {
        if model.isUpdatingKernel { return model.kernelUpdateStatus }
        switch kernelCheckState {
        case .idle:
            return nil
        case .checking:
            return "正在检查更新…"
        case .latest(let version):
            return "已是最新 \(version)"
        case .updateAvailable(let tag):
            return "有新版本 \(tag) 可用"
        }
    }

    private var isCheckingKernel: Bool {
        if case .checking = kernelCheckState { return true }
        return false
    }

    // MARK: 内核动作

    /// 用户点「检查更新」：一次 API 请求 → 与已安装版本比较 → 有差异才出现「更新到」按钮
    private func checkForUpdates() {
        guard !isCheckingKernel, !model.isUpdatingKernel else { return }
        kernelCheckState = .checking
        kernelNotice = nil
        Task {
            do {
                let latest = try await model.checkKernelUpdate()
                model.refreshKernelVersion()
                kernelVersion = model.kernelInstalledVersion
                // 相对判断：tag 直接比字符串（mihomo 不用语义版本排序）
                if model.kernelInstalledVersion == latest {
                    kernelCheckState = .latest(latest)
                } else {
                    kernelCheckState = .updateAvailable(latest)
                }
            } catch {
                kernelCheckState = .idle
                kernelNoticeIsError = true
                kernelNotice = (error as? KernelProvisionError)?.userMessage
                    ?? "检查更新失败：网络不可达，可换下载镜像后重试"
            }
        }
    }

    /// 用户确认「更新到 vX.Y.Z」：才下载资产（停内核 → 换文件 → 起内核）
    private func startKernelUpdate(_ tag: String) {
        guard !model.isUpdatingKernel else { return }
        kernelNotice = nil
        Task {
            let error = await model.updateKernel(to: tag)
            model.refreshKernelVersion()
            kernelVersion = model.kernelInstalledVersion
            if let error {
                kernelNoticeIsError = true
                kernelNotice = error
            } else {
                kernelNoticeIsError = false
                kernelNotice = "已更新到 \(tag)，内核已重启"
                kernelCheckState = .latest(tag)
            }
        }
    }

    /// 未安装态：直接走首次下载（本地没内核，不需要先比较版本）
    private func installKernel() {
        guard !model.isUpdatingKernel else { return }
        kernelNotice = nil
        Task {
            let error = await model.installKernelIfMissing()
            model.refreshKernelVersion()
            kernelVersion = model.kernelInstalledVersion
            if let error {
                kernelNoticeIsError = true
                kernelNotice = error
            } else {
                kernelNoticeIsError = false
                kernelNotice = "内核已安装并启动"
                kernelCheckState = .idle
            }
        }
    }

    // MARK: - 段五：组件与维护

    private var componentSection: some View {
        section("组件与维护") {
            VStack(alignment: .leading, spacing: Space.hair) {
                // 状态点 + 文案 + 右侧小按钮：四态（未安装 / 已安装 / 需要更新 / 未运行）互斥
                HStack(spacing: Space.s) {
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
                            .controlSize(.regular)
                    }
                }
                .frame(height: Metrics.formRowHeight)

                Text(helper.hintText)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Space.xs)

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

            VStack(alignment: .leading, spacing: Space.hair) {
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
                menuPicker(
                    accessibilityLabel: "日志级别",
                    options: LogLevelSetting.allCases,
                    selection: Binding(
                        get: { settings.logLevel },
                        set: { settings.logLevel = $0 }
                    ),
                    title: { $0.title }
                )
            }

            HStack(spacing: Space.m) {
                Button("打开配置目录") {
                    NSWorkspace.shared.open(AppPaths.supportDirectory)
                }
                .controlSize(.regular)

                Button("打开日志目录") {
                    NSWorkspace.shared.open(AppPaths.logsDirectory)
                }
                .controlSize(.regular)

                Spacer(minLength: 4)

                if isCleaningUp {
                    ProgressView()
                        .controlSize(.mini)
                }

                Button {
                    showsCleanupConfirmation = true
                } label: {
                    Text("彻底清理…")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.error)
                        .frame(height: Metrics.hitTarget)
                }
                .buttonStyle(.borderless)
                .disabled(isCleaningUp)
                .accessibilityHint(Text("还原系统代理、停止内核 / TUN，删除数据、缓存与偏好；App 本身保留"))
            }
            .frame(height: Metrics.formRowHeight)

            if let maintenanceNotice {
                noticeText(maintenanceNotice, isError: maintenanceFailed)
            }
        }
    }

    // MARK: - 段六：存储

    private var storageSection: some View {
        section("存储") {
            ForEach(storageTargets) { target in
                storageRow(target)
            }

            HStack(spacing: Space.s) {
                Text("体积按磁盘占用统计；缓存可安全删除")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Button(isMeasuringStorage ? "计算中…" : "刷新") {
                    refreshStorageUsage()
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .disabled(isMeasuringStorage)
            }
            .frame(height: Metrics.formRowHeight)
        }
    }

    /// 一行 = 名称 + 短路径 + 体积 + 在访达中显示
    private func storageRow(_ target: StorageTarget) -> some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(target.title)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(target.displayPath)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(target.url.path)
            }

            Spacer(minLength: 4)

            Text(storageSizeText(for: target))
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                .lineLimit(1)

            IconButtonView(systemName: "folder", label: "在访达中显示") {
                revealInFinder(target)
            }
        }
        .frame(height: Metrics.formRowHeight + 8)
    }

    private func storageSizeText(for target: StorageTarget) -> String {
        switch storageStates[target.kind] ?? .loading {
        case .loading: "计算中…"
        case .bytes(let bytes): TrafficFormat.bytes(bytes)
        case .unavailable(let reason): reason
        }
    }

    private func revealInFinder(_ target: StorageTarget) {
        // 目录不存在时退到父目录，避免按钮点了没反应
        let url = FileManager.default.fileExists(atPath: target.url.path)
            ? target.url
            : target.url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 进入页面 / 点「刷新」时算一次；体积全部在后台，body 里只读结果
    private func refreshStorageUsage() {
        let targets = StorageUsageProbe.targets(includeHelper: HelperInstaller.isInstalled)
        storageTargets = targets
        for target in targets {
            storageStates[target.kind] = .loading
        }
        isMeasuringStorage = true

        Task {
            var measured: [StorageTarget.Kind: StorageSizeState] = [:]
            await withTaskGroup(of: (StorageTarget.Kind, StorageSizeState).self) { group in
                for target in targets {
                    group.addTask {
                        (target.kind, await StorageUsageProbe.measure(target.url))
                    }
                }
                for await (kind, state) in group {
                    measured[kind] = state
                }
            }
            storageStates = measured
            isMeasuringStorage = false
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

    /// 一段 = 11pt 段名 + 一张卡（行与行之间不画线，靠行高与对齐区分）
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title)
                .font(Typography.section)
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, Space.s)
            .background {
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .fill(Theme.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: Metrics.cardStroke)
                    }
                    .compositingGroup()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 36pt 行：label 左、控件右；控件命中区不小于 28pt
    private func row<Content: View>(
        _ title: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(spacing: Space.l) {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: Space.l)

            control()
        }
        .frame(height: Metrics.formRowHeight)
    }

    /// 设置页所有下拉共用：系统 `Picker(.menu)`——自带下拉箭头、整块按钮可点、hover 有反馈。
    ///
    /// 之前用 `Menu` + `.menuStyle(.borderlessButton)` + `.fixedSize()`：命中区只剩那行文字，
    /// 行右侧空白点了没反应；`.menuIndicator(.hidden)` 又把「可点」的提示抹掉了。
    private func menuPicker<Item: Hashable>(
        accessibilityLabel: String,
        options: [Item],
        selection: Binding<Item>,
        title: @escaping (Item) -> String
    ) -> some View {
        Picker(accessibilityLabel, selection: selection) {
            ForEach(options, id: \.self) { item in
                Text(title(item)).tag(item)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.large)
        .fixedSize()
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(title(selection.wrappedValue)))
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
        // 本页的选择状态要立刻同步：只写 settings 不足以驱动「自定义 → 输入框」的切换
        uaChoice = choice
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
            maintenanceNotice = error ?? "已清理。请退出并重新打开 Clash（不会自动退出），以便重建数据目录。"
        }
    }
}

/// 设置页「内核」一节的检查状态：与升级动作分离，`updateAvailable` 才会出现下载按钮。
private enum KernelCheckState: Equatable {
    case idle
    case checking
    case latest(String)
    case updateAvailable(String)
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
