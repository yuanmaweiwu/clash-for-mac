import SwiftUI

/// 代理模式磁贴：14pt 标题 + 153×28 轨道（§4.3）。
@MainActor
struct ProxyModeTileView: View {
    let mode: ProxyMode
    let onSelect: (ProxyMode) -> Void

    var body: some View {
        TilePanel {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("代理模式")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                SegmentBarView(selection: mode, onSelect: onSelect)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
