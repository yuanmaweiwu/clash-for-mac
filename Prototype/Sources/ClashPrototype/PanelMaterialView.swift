import AppKit
import SwiftUI

/// 全应用唯一一处材质：面板底。
///
/// 正式 App 里这里是 `NSVisualEffectView` + `.behindWindow`（透过窗口看桌面）；
/// 原型把壁纸画在同一个窗口里，所以用 `.withinWindow` 让材质真正模糊这块壁纸，
/// 仍然是系统材质，不是自绘假模糊。
@MainActor
struct PanelMaterialView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
