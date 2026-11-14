import SwiftUI

/// 代理模式磁贴：13pt 标题（`font/body`，与同排「系统代理」同阶）+ 153×28 轨道（§4.3）。
///
/// 磁贴高 64：标题 13 + 间距 4 + 轨道 28 = 45，上下各余 9.5，不裁切。
@MainActor
struct ProxyModeTileView: View {
    let mode: ProxyMode
    let onSelect: (ProxyMode) -> Void

    var body: some View {
        TilePanel {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("代理模式")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                SegmentBarView(selection: mode, onSelect: onSelect)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
