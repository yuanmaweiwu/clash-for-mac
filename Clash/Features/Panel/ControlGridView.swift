import SwiftUI

/// 主控区 138pt：2×2 磁贴，153×64、gap 10（§3.2）。
@MainActor
struct ControlGridView: View {
    let model: PanelPreviewModel

    var body: some View {
        VStack(spacing: Metrics.tileGap) {
            HStack(spacing: Metrics.tileGap) {
                ConnectionTileView(state: model.connectionState) {
                    model.toggleConnection()
                }
                .disabled(model.isConnectionBusy)
                ProxyModeTileView(mode: model.mode) { mode in
                    model.selectMode(mode)
                }
            }
            HStack(spacing: Metrics.tileGap) {
                // TUN：五态驱动（§4.2）。过渡 / 等待授权期间禁用，避免重复点击
                TunTileView(state: model.tunState) {
                    model.toggleTun()
                }
                .disabled(model.isTunBusy)
                SubscriptionTileView(content: model.subscriptionTileContent) {
                    model.openSubscriptions()
                }
            }
        }
        .frame(height: Metrics.controlHeight, alignment: .top)
    }
}
