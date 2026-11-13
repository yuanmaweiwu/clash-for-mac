import SwiftUI

/// 主控区 138pt：2×2 磁贴，153×64、gap 10（§3.2）。
@MainActor
struct ControlGridView: View {
    let model: PanelPreviewModel

    var body: some View {
        VStack(spacing: Metrics.tileGap) {
            HStack(spacing: Metrics.tileGap) {
                ConnectionTileView(status: model.status) {
                    model.toggleConnection()
                }
                .disabled(model.isKernelBusy)
                ProxyModeTileView(mode: model.mode) { mode in
                    model.selectMode(mode)
                }
            }
            HStack(spacing: Metrics.tileGap) {
                // v0.1 TUN 不可用（ADR-0007）：点击只解释原因，不做假开关
                TunTileView {
                    PlaceholderPanel.show(
                        title: "TUN",
                        detail: "TUN 需要管理员组件，v0.2 随系统代理一起接入。"
                    )
                }
                SubscriptionTileView(
                    profileName: model.subscriptionTileSubtitle,
                    badgeCount: model.subscriptionBadgeCount
                ) {
                    model.openSubscriptions()
                }
            }
        }
        .frame(height: Metrics.controlHeight, alignment: .top)
    }
}
