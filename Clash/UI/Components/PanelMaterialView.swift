import AppKit
import SwiftUI

/// 全应用唯一一处材质：面板底。
///
/// 正式 App 的浮层窗口是透明的，所以用 `.behindWindow` 直接模糊窗口背后的桌面
/// （与系统控制中心一致），而不是 `.withinWindow` 去模糊窗口内自绘的壁纸。
///
/// 设计语言策略见 `docs/adr/0009`：**所有系统保持一致，不为 macOS 26+ 出第二套皮肤**。
/// 若将来要上 Liquid Glass，只改这里（26+ 判断 + `NSGlassEffectView`），
/// 卡片仍是半透明 fill，且必须先验对比度、Reduce Transparency、浮层边缘三件事。
/// 现在不留空分支。
@MainActor
struct PanelMaterialView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
