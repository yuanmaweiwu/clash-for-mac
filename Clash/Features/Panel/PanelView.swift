import SwiftUI

/// 340pt 宽的控制面板本体（§3.1 线框 / §3.2 分区规格）。
///
/// 结构固定为：状态条 +（banner）+ 主控区 + 曲线卡 + 可滚动分组区 + 底栏。
/// 高度由内容自然决定；banner 出现时从分组区里扣，总高不变。
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

    /// pin 变化时面板高度的过渡（motion/list）
    private var heightAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.15)
            : .spring(response: 0.28, dampingFraction: 0.80)
    }

    var body: some View {
        ZStack {
            PanelMaterialView()
            Theme.panelScrim
            panelContent
        }
        .frame(width: Metrics.panelWidth)
        // 材质层是弹性的，不锁高度的话会被窗口高度撑满；这里始终取内容自然高度
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(panelShape)
        .overlay {
            panelShape.strokeBorder(Theme.hairline, lineWidth: Metrics.hairline)
        }
        .animation(pushAnimation, value: model.route)
        .animation(heightAnimation, value: model.pinnedGroupIDs)
        .background {
            EscapeKeyHandler(model: model, onEscape: onClose)
        }
        .onExitCommand {
            if model.route != .root {
                model.popToRoot()
            } else {
                onClose()
            }
        }
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
                        model.popToRoot()
                    }
                }
            }
        case .allGroups:
            pushedContent {
                AllGroupsPanelView(model: model) {
                    model.popToRoot()
                }
            }
        case .subscriptions:
            pushedContent {
                SubscriptionPanelView(model: model) {
                    model.popToRoot()
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
                showsRates: model.showsLiveTraffic,
                downText: model.downRateText,
                upText: model.upRateText
            )

            // 顶部 banner：插在状态条正下方，占固定高度，不把面板撑高（§7）
            if let message = model.errorMessage {
                ErrorBannerView(message: message) {
                    PlaceholderPanel.show(
                        title: "日志",
                        detail: "日志窗口会在接入内核后提供，先在这里展示内核输出。"
                    )
                }
                .padding(.top, Metrics.bannerSpacing)
                .padding(.bottom, Metrics.bannerSpacing)
            }

            ControlGridView(model: model)

            TrafficCardView(
                showsRates: model.showsLiveTraffic,
                downRate: model.downRate,
                upRate: model.upRate,
                downSeries: model.downSeries,
                upSeries: model.upSeries
            )
            .padding(.top, Metrics.tileGap)

            GroupSectionView(model: model)
                .padding(.top, Metrics.tileGap)
                .opacity(model.isGroupDisabled ? 0.45 : 1)
                .disabled(model.isGroupDisabled)

            FooterView(
                // 底栏时间取自 active 订阅的 updatedAt；没订阅才写「未导入配置」
                updatedText: model.footerUpdatedText,
                // v0.2：换成 /connections 的真实连接数
                connectionCount: nil,
                kernelVersion: model.kernelVersion,
                onRefresh: { model.refreshProfile() }
            )
            .padding(.top, Metrics.tileGap)
        }
        .padding(.horizontal, Metrics.panelPadding)
        .padding(.vertical, Metrics.panelPadding)
    }
}

#if DEBUG
// Preview 夹具用到 DEBUG-only 的模型方法，整套只在 Debug 编译（Release 不加载概览）
#Preview("首层 · 单卡") {
    PanelView(model: PanelPreviewModel(autoStartsKernel: false))
}

#Preview("首层 · 双卡 + 失败") {
    PanelView(model: panelPreviewModel(pinnedFailure: true))
}

#Preview("空态") {
    PanelView(model: panelPreviewModel(empty: true))
}

/// Preview 夹具：直接摆出评审批次里的几种面板形态。
@MainActor
private func panelPreviewModel(pinnedFailure: Bool = false, empty: Bool = false) -> PanelPreviewModel {
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
    if pinnedFailure {
        model.pinAllPreviewGroups()
        model.previewFailure()
    }
    return model
}
#endif
