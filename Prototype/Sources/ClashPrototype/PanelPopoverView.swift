import AppKit
import SwiftUI

/// 状态栏浮层内容：纯面板、无壁纸、无自绘投影（系统弹层自带边缘）。
@MainActor
struct PanelPopoverView: View {
    let model: PrototypeModel

    var body: some View {
        PanelView(model: model, showsShadow: false) {
            PopoverCloser.close()
        }
    }
}
