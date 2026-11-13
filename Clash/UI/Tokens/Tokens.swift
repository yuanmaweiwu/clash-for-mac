import AppKit
import SwiftUI

// MARK: - 色值口径
//
// 1. 颜色只有一处定义：本文件。视图里不写 hex、不写 Color.black.opacity。
// 2. 浅/深色只在 `dynamic(light:dark:)` 的 provider 里分流一次；
//    视图层不判断当前外观（不用环境里的外观值）。
// 3. 数值全部来自 `docs/02-UI-SPEC.md` §2（Token）与 §3.2（分区规格）。

// 注意：SwiftUI 会在后台线程解析动态色，这几个构造与 provider 闭包必须保持
// nonisolated（不要塞进 @MainActor 类型里），否则会触发队列断言崩溃。
private func clashDynamicColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? dark : light
    }
}

private func clashRGB(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

private func clashWhite(_ alpha: CGFloat) -> NSColor {
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
}

private func clashBlack(_ alpha: CGFloat) -> NSColor {
    NSColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha)
}

@MainActor
enum Theme {

    // MARK: 表面层级 surface/*

    static let panelScrim = Color(nsColor: clashDynamicColor(light: clashWhite(0.22), dark: clashBlack(0.24)))
    static let card = Color(nsColor: clashDynamicColor(light: clashWhite(0.55), dark: clashWhite(0.06)))
    static let cardHover = Color(nsColor: clashDynamicColor(light: clashWhite(0.62), dark: clashWhite(0.10)))
    static let rowHover = Color(nsColor: clashDynamicColor(light: clashBlack(0.08), dark: clashWhite(0.10)))
    static let rowSelected = Color(nsColor: clashDynamicColor(light: clashRGB(0x007AFF, 0.16), dark: clashRGB(0x0A84FF, 0.22)))
    static let track = Color(nsColor: clashDynamicColor(light: clashBlack(0.06), dark: clashWhite(0.08)))
    static let opaque = Color(nsColor: clashDynamicColor(light: clashRGB(0xFFFFFF), dark: clashRGB(0x1E1E20)))

    // MARK: 描边与阴影

    static let hairline = Color(nsColor: clashDynamicColor(light: clashBlack(0.10), dark: clashWhite(0.12)))
    static let emphasis = Color(nsColor: clashDynamicColor(light: clashBlack(0.18), dark: clashWhite(0.22)))
    static let errorStroke = Color(nsColor: clashDynamicColor(light: clashRGB(0xD70015, 0.30), dark: clashRGB(0xFF453A, 0.35)))
    static let accentStroke = Color(nsColor: clashDynamicColor(light: clashRGB(0x007AFF, 0.35), dark: clashRGB(0x0A84FF, 0.40)))
    static let panelShadow = Color(nsColor: clashDynamicColor(light: clashBlack(0.18), dark: clashBlack(0.50)))
    /// 键盘焦点环 2pt、外扩 2pt（§2.2 / §6.2）
    static let focus = Color(nsColor: clashDynamicColor(light: clashRGB(0x007AFF, 0.70), dark: clashRGB(0x0A84FF, 0.70)))

    // MARK: 文本

    static let textPrimary = Color(nsColor: clashDynamicColor(light: clashBlack(0.88), dark: clashWhite(0.94)))
    static let textSecondary = Color(nsColor: clashDynamicColor(light: clashBlack(0.55), dark: clashWhite(0.62)))
    static let textTertiary = Color(nsColor: clashDynamicColor(light: clashBlack(0.36), dark: clashWhite(0.42)))
    static let textOnAccent = Color(nsColor: clashRGB(0xFFFFFF))

    // MARK: 语义色

    static let accent = Color(nsColor: clashDynamicColor(light: clashRGB(0x007AFF), dark: clashRGB(0x0A84FF)))
    static let success = Color(nsColor: clashDynamicColor(light: clashRGB(0x1E8E3E), dark: clashRGB(0x30D158)))
    static let warning = Color(nsColor: clashDynamicColor(light: clashRGB(0xB25000), dark: clashRGB(0xFFD60A)))
    static let error = Color(nsColor: clashDynamicColor(light: clashRGB(0xD70015), dark: clashRGB(0xFF453A)))

    static let latencyOk = Color(nsColor: clashDynamicColor(light: clashRGB(0xA07A00), dark: clashRGB(0xFFD60A)))
    static let latencySlow = Color(nsColor: clashDynamicColor(light: clashRGB(0xB25000), dark: clashRGB(0xFF9F0A)))

    static let trafficDown = Color(nsColor: clashDynamicColor(light: clashRGB(0x007AFF), dark: clashRGB(0x0A84FF)))
    static let trafficUp = Color(nsColor: clashDynamicColor(light: clashRGB(0x30B0C7), dark: clashRGB(0x40C8E0)))
}

// MARK: - 字体（系统字体，固定字号，不接 Dynamic Type）

@MainActor
enum Typography {
    /// 11 / semibold —— 区块标题、图例
    static let section = Font.system(size: 11, weight: .semibold)
    /// 13 / semibold —— 卡片头、选中节点名
    static let title = Font.system(size: 13, weight: .semibold)
    /// 13 / regular —— 节点名、磁贴标题
    static let body = Font.system(size: 13, weight: .regular)
    /// 11 / regular —— 副标题、单位
    static let caption = Font.system(size: 11, weight: .regular)
    /// 12 / medium + 等宽数字 —— 延迟、行内速率
    static let number = Font.system(size: 12, weight: .medium).monospacedDigit()
    /// 13 / medium + 等宽数字 —— 状态条速率
    static let numberLarge = Font.system(size: 13, weight: .medium).monospacedDigit()
    /// 12 / medium —— 状态条文案
    static let status = Font.system(size: 12, weight: .medium)
}

// MARK: - 尺寸与间距（§2.6 / §2.7 / §3.2）

@MainActor
enum Metrics {
    // 面板
    static let panelWidth: CGFloat = 340
    static let panelPadding: CGFloat = 12
    /// 双卡满态高度（上限 656）
    static let panelHeight: CGFloat = 642

    // 分区
    static let statusBarHeight: CGFloat = 36
    static let controlHeight: CGFloat = 138
    static let chartCardHeight: CGFloat = 80
    static let chartHeight: CGFloat = 40
    static let groupTitleHeight: CGFloat = 20
    static let groupCardHeight: CGFloat = 136
    /// 双卡满态：20 + 136 + 10 + 136
    static let groupSectionFullHeight: CGFloat = 302
    static let emptyGroupCardHeight: CGFloat = 120
    static let footerHeight: CGFloat = 32
    static let bannerHeight: CGFloat = 36
    /// banner 与上下内容的间距
    static let bannerSpacing: CGFloat = 8
    /// banner 连同上下间距一起占的高度：出现在固定头部，从分组区扣
    static var bannerBlockHeight: CGFloat { bannerHeight + bannerSpacing * 2 }

    // 磁贴与行
    static let tileWidth: CGFloat = 153
    static let tileHeight: CGFloat = 64
    static let tileGap: CGFloat = 10
    static let segmentHeight: CGFloat = 28
    static let cardHeaderHeight: CGFloat = 32
    static let rowHeight: CGFloat = 32
    static let cardPadding: CGFloat = 10
    /// 卡片上下内边距：卡头 hover 胶囊距卡顶 = 4 + 2 = 6pt
    static let cardInsetV: CGFloat = 4
    /// 一级卡片 hover / 选中胶囊：左右 6、上下 2（32pt 行 → 胶囊 28，文字距胶囊边 4）
    static let pillInsetH: CGFloat = 6
    static let pillInsetV: CGFloat = 2
    /// 二级列表（44/48pt 行）胶囊：上下 4（行高更高，胶囊更厚）
    static let listPillInsetV: CGFloat = 4

    // 圆角
    static let radiusPanel: CGFloat = 12
    static let radiusCard: CGFloat = 10
    static let radiusRow: CGFloat = 6
    static let radiusTrack: CGFloat = 7

    /// 1px = 1 / displayScale
    static let hairline: CGFloat = 1 / max(2, NSScreen.main?.backingScaleFactor ?? 2)
    /// 卡片 / 磁贴描边：固定 1pt（2x 下 2px，连续），不用 0.5pt
    static let cardStroke: CGFloat = 1

    /// 分组区高度：区块标题 20 + N 张卡 + 卡间 10
    static func groupSectionHeight(forCards count: Int) -> CGFloat {
        let cards = CGFloat(max(count, 0))
        let gaps = CGFloat(max(count - 1, 0)) * tileGap
        return groupTitleHeight + cards * groupCardHeight + gaps
    }
}
