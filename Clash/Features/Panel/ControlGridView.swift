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
                ProxyModeTileView(mode: model.mode) { mode in
                    model.selectMode(mode)
                }
            }
            HStack(spacing: Metrics.tileGap) {
                TunTileView(state: model.tun) {
                    model.toggleTun()
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
