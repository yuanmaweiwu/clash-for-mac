#if DEBUG
import SwiftUI

/// 两个开关磁贴的全状态板（仅 Debug，供文案与配色走查用）。
///
/// `Scripts/ui-preview.sh tiles out.png` 直接渲染本视图：不建模型、不碰内核 / 系统代理，
/// 磁贴状态全用字面量构造。用途是核对「系统代理」与「TUN 模式」两列副标题是否同一个词根
/// （未启用 / 进行中 / 已启用 / 失败），以及互斥微文案的显字与留白。
@MainActor
struct TileStateBoardView: View {
    private let proxyStates: [(String, ConnectionState)] = [
        ("未启用", .off),
        ("正在启用", .turningOn),
        ("已启用", .on),
        ("正在停用", .turningOff),
        ("启用失败", .failed(.enable)),
        ("停用失败", .failed(.disable)),
    ]

    private let tunStates: [(String, TunState)] = [
        ("未启用", .off),
        ("需要授权", .requiresAuth),
        ("等待授权", .waitingAuth),
        ("正在启用", .starting),
        ("已启用", .on),
        ("正在停用", .stopping),
        ("授权失败", .authFailed),
        ("启用失败", .startFailed),
    ]

    var body: some View {
        ZStack {
            PanelMaterialView()
            Theme.panelScrim
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .top, spacing: Space.xxl) {
                    column("系统代理") {
                        ForEach(proxyStates, id: \.0) { key, state in
                            row(key) { ConnectionTileView(state: state) {} }
                        }
                    }
                    column("TUN 模式") {
                        ForEach(tunStates, id: \.0) { key, state in
                            row(key) { TunTileView(state: state) {} }
                        }
                    }
                }
                hintRows
            }
            .padding(Metrics.panelPadding)
        }
        .frame(width: 560)
    }

    /// 互斥微文案：都未启用时显字；任一路由启用后只留恒定留白（面板高度不变）
    private var hintRows: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("都未启用 → 露出提示")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
            TransportHintView(isVisible: true)

            Text("任一已启用 → 只留留白，高度不变")
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
            TransportHintView(isVisible: false)
                .background(Theme.track)
        }
    }

    private func column<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(title)
                .font(Typography.title)
                .foregroundStyle(Theme.textPrimary)
            content()
        }
    }

    private func row<Content: View>(_ key: String, @ViewBuilder tile: () -> Content) -> some View {
        HStack(spacing: Space.m) {
            tile()
            Text(key)
                .font(Typography.caption)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
    }
}
#endif
