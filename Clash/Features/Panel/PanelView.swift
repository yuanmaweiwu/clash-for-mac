import AppKit
import SwiftUI

/// 340pt 宽的控制面板本体（§3.1 线框 / §3.2 分区规格）。
///
/// 结构固定为：状态条 +（banner）+ 主控区 + 曲线卡 + 可滚动尾区（网络检测 + 策略组）+ 底栏。
/// 总高由 `model.panelHeight` 瞬时决定（窗口同帧跟尺寸）；banner 出现时从尾区里扣，总高不变。
@MainActor
struct PanelView: View {
    let model: PanelPreviewModel
    var onClose: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
    }

    private var pushTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 16))
    }

    private var pushAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.15)
            : .spring(response: 0.32, dampingFraction: 0.90)
    }

    var body: some View {
        ZStack {
            PanelMaterialView()
            Theme.panelScrim
            // 页面切换的淡入位移挂在「内容容器」上，外层尺寸由 `model.panelHeight` 瞬时决定：
            // 容器的滚动/高度动画不会改变面板外形，四角始终是同一条 16pt 圆角。
            VStack(spacing: 0) {
                panelContent
            }
            .frame(width: Metrics.panelWidth)
            .animation(pushAnimation, value: model.route)
        }
        .frame(width: Metrics.panelWidth, height: model.panelHeight)
        // 高度变化不参与任何动画：弹簧动画会让内容短暂低于目标高，窗口的 fitting 尺寸
        // 跟着抖一下（实测 629 vs 634），窗口把圆角切掉、露出直角帧。
        .animation(nil, value: model.panelHeight)
        .clipShape(panelShape)
        .overlay {
            panelShape.strokeBorder(Theme.hairline, lineWidth: Metrics.hairline)
        }
        .background {
            EscapeKeyHandler(model: model, onEscape: onClose)
        }
        .onExitCommand {
            if model.route != .root {
                model.popRoute()
            } else {
                onClose()
            }
        }
        // TUN 授权说明卡：声明式 alert（不用 NSAlert.runModal，避免不可见模态会话吞点击）
        .alert(
            TunInstallPrompt.title(updating: model.tunInstallPrompt == .outdated),
            isPresented: installPromptBinding
        ) {
            Button("取消", role: .cancel) { model.cancelTunInstall() }
            Button("继续") { model.confirmTunInstall() }
        } message: {
            Text(TunInstallPrompt.message)
        }
    }

    /// 关闭 alert 时不带选择（Esc / 点外部）→ 只收起说明卡，保持「需要授权」
    private var installPromptBinding: Binding<Bool> {
        Binding(
            get: { model.tunInstallPrompt != nil },
            set: { isPresented in
                guard !isPresented else { return }
                model.dismissTunInstallPrompt()
            }
        )
    }

    @ViewBuilder
    private var panelContent: some View {
        switch model.route {
        case .root:
            rootContent
                .transition(pushTransition)
        case .nodes(let id):
            if let group = model.allGroups.first(where: { $0.id == id }) {
                pushedContent {
                    NodeListPanelView(model: model, group: group) {
                        model.popRoute()
                    }
                }
            }
        case .allGroups:
            pushedContent {
                AllGroupsPanelView(model: model) {
                    model.popRoute()
                }
            }
        case .subscriptions:
            pushedContent {
                SubscriptionPanelView(model: model) {
                    model.popRoute()
                }
            }
        case .subscriptionNew:
            pushedContent {
                SubscriptionNewPanelView(model: model) {
                    model.popRoute()
                }
            }
        case .connections:
            pushedContent {
                ConnectionsPanelView(model: model) {
                    model.popRoute()
                }
            }
        case .rules:
            pushedContent {
                RulesPanelView(model: model) {
                    model.popRoute()
                }
            }
        case .settings:
            pushedContent {
                SettingsPanelView(model: model, settings: model.settings) {
                    model.popRoute()
                }
            }
        }
    }

    private func pushedContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.vertical, Metrics.panelPadding)
            .transition(pushTransition)
    }

    private var rootContent: some View {
        VStack(spacing: 0) {
            StatusStripView(
                status: model.status,
                detail: model.kernelUpdateStatus
                    ?? (model.phase == .starting ? model.kernelProvisioningStage : nil),
                showsRates: model.showsLiveTraffic,
                downText: model.downRateText,
                upText: model.upRateText
            )

            // 顶部 banner：插在状态条正下方，占固定高度，不把面板撑高（§7）
            if let message = model.errorMessage {
                ErrorBannerView(message: message) {
                    openLogs()
                }
                .padding(.top, Metrics.bannerSpacing)
                .padding(.bottom, Metrics.bannerSpacing)
            }

            ControlGridView(model: model)
                .padding(.top, Metrics.sectionGap)

            TrafficCardView(
                hasCurve: model.hasTrafficCurve,
                isLive: model.showsLiveTraffic,
                downRate: model.downRate,
                upRate: model.upRate,
                downSeries: model.downSeries,
                upSeries: model.upSeries
            )
            .padding(.top, Metrics.sectionGap)

            // 网络检测 + 策略组共用一块滚动区：新增 88pt 后双卡态仍能塞进 680，
            // 由这里吸收溢出，状态条 / 磁贴 / 曲线 / 底栏都不压缩（§3.5）
            scrollTail
                .padding(.top, Metrics.sectionGap)

            FooterView(
                onOpenConnections: { model.openConnections() },
                onOpenRules: { model.openRules() },
                onOpenSettings: { model.openSettingsPage() }
            )
            .padding(.top, Space.m)
        }
        .padding(.horizontal, Metrics.panelPadding)
        .padding(.vertical, Metrics.panelPadding)
    }

    /// 可滚动尾区：网络检测在上、策略组在下，同一块滚动容器里
    private var scrollTail: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                NetworkProbeSectionView(model: model)

                GroupSectionView(model: model)
                    .padding(.top, Metrics.sectionGap)
                    .opacity(model.isGroupDisabled ? 0.45 : 1)
                    .disabled(model.isGroupDisabled)
            }
        }
        .scrollIndicators(.never)
        .frame(height: model.scrollTailHeight, alignment: .top)
        .clipped()
    }

    /// 底栏「日志」/ 失败 banner：打开独立日志窗口（单例，重复点击只聚焦），并收起面板浮层
    private func openLogs() {
        AppEnvironment.shared.openLogsWindow()
        // LSUIElement 应用不会自动到前台，窗口不激活的话用户看不到刚打开的日志
        NSApp.activate(ignoringOtherApps: true)

        // 面板自己 `.close()` 时看不见（此时 key 已是日志窗口），这里按层级关掉浮层：
        // 面板是 `.popUpMenu` 级别的 NSPanel，状态栏图标窗口是 `.statusBar`，不会被误关
        for window in NSApp.windows where window.isVisible && window.level == .popUpMenu {
            window.close()
        }
    }
}

#if DEBUG
// Preview 夹具用到 DEBUG-only 的模型方法，整套只在 Debug 编译（Release 不加载概览）
#Preview("首层 · 单卡") {
    PanelView(model: PanelPreviewModel(autoStartsKernel: false))
}

#Preview("首层 · 失败") {
    PanelView(model: panelPreviewModel(failed: true))
}

#Preview("空态") {
    PanelView(model: panelPreviewModel(empty: true))
}

/// Preview 夹具：直接摆出评审批次里的几种面板形态。
@MainActor
private func panelPreviewModel(failed: Bool = false, empty: Bool = false) -> PanelPreviewModel {
    // 用到的是公开 init，预览不读真实 `profiles/index.json`
    let directory = URL.temporaryDirectory.appending(
        path: "clash-preview-\(empty ? "empty" : "default")",
        directoryHint: .isDirectory
    )
    let model = PanelPreviewModel(
        profileStore: ProfileStore(directory: directory),
        // 预览不读写真实系统代理快照
        systemProxy: SystemProxyService(
            snapshotURL: directory.appending(path: "systemproxy-snapshot.json")
        ),
        // 预览不启动真实内核
        autoStartsKernel: false
    )
    if !empty {
        model.applyPreviewGroups()
    }
    if failed {
        model.previewFailure()
    }
    return model
}
#endif
