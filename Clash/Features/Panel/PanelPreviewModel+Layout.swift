import CoreGraphics

// MARK: - 布局派生值
//
// 面板高度 = 内容自然高度（§3.5）；banner 在固定头部占位，只从分组区里扣。

extension PanelPreviewModel {
    /// 分组区自然高度（不扣 banner：banner 只压缩可视窗口，不压内容本身）
    var groupSectionContentHeight: CGFloat {
        if groups.isEmpty { return Metrics.emptyGroupCardHeight }
        // 单选：永远只有一张卡（`displayedGroup` 在 groups 非空时必有兜底值）
        return Metrics.groupSectionHeight(forCards: 1)
    }

    /// 可滚动尾区（网络检测 + 策略组）的完整内容高度
    var scrollTailContentHeight: CGFloat {
        Metrics.probeSectionHeight + Metrics.sectionGap + groupSectionContentHeight
    }

    /// 尾区可视高度：上限 314（680 − 固定头部 314 − 底栏块 52），banner 出现再扣一条
    var scrollTailHeight: CGFloat {
        let available = Metrics.scrollTailMaxHeight - (showsErrorBanner ? Metrics.bannerBlockHeight : 0)
        return min(scrollTailContentHeight, max(available, 0))
    }

    /// 面板应有的总高（§3.2）：由路由与尾区内容**瞬时**决定，窗口直接跟这个值走。
    ///
    /// 不让 SwiftUI 去动画内容高度：背景的 16pt 圆角是内容自己画的，一旦窗口和内容
    /// 各走一条动画，中间帧就会出现直角（`PanelWindowController` 也不再动画 frame）。
    var panelHeight: CGFloat {
        guard route == .root else { return Metrics.panelHeightMax }
        return Metrics.panelChromeHeight + min(scrollTailContentHeight, Metrics.scrollTailMaxHeight)
    }

    /// 内核启动失败：分组区变暗并禁用（§7）
    var isGroupDisabled: Bool { showsErrorBanner || status == .failed }
}
