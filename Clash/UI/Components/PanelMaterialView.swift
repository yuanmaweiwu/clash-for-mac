import AppKit
import SwiftUI

/// 全应用唯一一处材质：面板底。
///
/// 正式 App 的浮层窗口是透明的，所以用 `.behindWindow` 直接模糊窗口背后的桌面
/// （与系统控制中心一致），而不是 `.withinWindow` 去模糊窗口内自绘的壁纸。
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
