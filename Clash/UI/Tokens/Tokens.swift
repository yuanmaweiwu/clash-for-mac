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

/// 压壁纸的强度（面板底 scrim）。
///
/// 壁纸是深色地图时，材质会被染成中灰；scrim 负责把面板拉回稳定的浅/深底。
/// 三档只在预览与调参时切换，正式运行取 `Theme.scrimStyle` 的默认值。
enum ScrimStyle: String, CaseIterable, Sendable {
    /// A 轻透：壁纸参与最多
    case light
    /// B 中等（默认）：浅色底压到接近系统浅灰，深色底仍透
    case balanced
    /// C 实底：几乎不透过壁纸
    case solid
}

@MainActor
enum Theme {

    // MARK: 表面层级 surface/*

    /// 当前 scrim 档位；调试可用 `CLASH_SCRIM_VARIANT` 覆盖（见 `UIPreviewHarness`）
    static var scrimStyle: ScrimStyle = .balanced

    private static var scrimAlpha: (light: CGFloat, dark: CGFloat) {
        switch scrimStyle {
        case .light: (0.28, 0.28)
        case .balanced: (0.42, 0.40)
        case .solid: (0.62, 0.60)
        }
    }

    private static var cardAlpha: (light: CGFloat, dark: CGFloat) {
        switch scrimStyle {
        case .light: (0.58, 0.07)
        case .balanced: (0.62, 0.10)
        case .solid: (0.70, 0.14)
        }
    }

    /// 面板底压壁纸的叠加层：缺了它，深色壁纸会把整块面板染成中灰
    static var panelScrim: Color {
        let alpha = scrimAlpha
        return Color(nsColor: clashDynamicColor(light: clashWhite(alpha.light), dark: clashBlack(alpha.dark)))
    }

    /// 分组卡 / 磁贴底：半透明 fill，靠 1pt 描边分层，卡内零阴影
    static var card: Color {
        let alpha = cardAlpha
        return Color(nsColor: clashDynamicColor(light: clashWhite(alpha.light), dark: clashWhite(alpha.dark)))
    }

    /// 卡片 hover：在 card 上叠一层很轻的黑/白
    static var cardHover: Color {
        let alpha = cardAlpha
        return Color(nsColor: clashDynamicColor(
            light: clashRGB(0xE9E9EB, alpha.light),
            dark: clashWhite(min(alpha.dark + 0.03, 0.9))
        ))
    }

    /// 卡片按下：hover 再深一档（§2.2：press 0.12 黑 / 0.14 白）
    static var cardPressed: Color {
        Color(nsColor: clashDynamicColor(light: clashBlack(0.12), dark: clashWhite(0.14)))
    }

    static let rowHover = Color(nsColor: clashDynamicColor(light: clashBlack(0.08), dark: clashWhite(0.10)))
    /// 选中行：强调色只做一层薄底，文字仍用正文色（不铺面积）
    static var rowSelected: Color {
        Color(nsColor: .controlAccentColor).opacity(0.14)
    }
    static let track = Color(nsColor: clashDynamicColor(light: clashBlack(0.06), dark: clashWhite(0.08)))
    /// 需要绝对对比的区域（banner / 分段选中段）：近白 / 近黑，不用纯色
    static let opaque = Color(nsColor: clashDynamicColor(light: clashRGB(0xFDFDFD), dark: clashRGB(0x1F1F22)))

    // MARK: 描边与阴影

    static let hairline = Color(nsColor: clashDynamicColor(light: clashBlack(0.10), dark: clashWhite(0.12)))
    static let emphasis = Color(nsColor: clashDynamicColor(light: clashBlack(0.18), dark: clashWhite(0.22)))
    static let errorStroke = Color(nsColor: clashDynamicColor(light: clashRGB(0xD70015, 0.30), dark: clashRGB(0xFF453A, 0.35)))
    static var accentStroke: Color { Color(nsColor: .controlAccentColor).opacity(0.40) }
    static let panelShadow = Color(nsColor: clashDynamicColor(light: clashBlack(0.18), dark: clashBlack(0.50)))
    /// 键盘焦点环 2pt、外扩 2pt（§2.2 / §6.2）
    static var focus: Color { hidesFocusRing ? .clear : Color(nsColor: .controlAccentColor).opacity(0.70) }

    /// 截图走查用：把焦点环画成透明（不影响真实运行）
    static var hidesFocusRing = false

    // MARK: 文本（不写纯黑 / 纯白；正文压到 4.5:1 以上）

    static let textPrimary = Color(nsColor: clashDynamicColor(light: clashRGB(0x1D1D1F), dark: clashRGB(0xF5F5F7)))
    static let textSecondary = Color(nsColor: clashDynamicColor(light: clashRGB(0x4A4A4F), dark: clashRGB(0xC7C7CC)))
    static let textTertiary = Color(nsColor: clashDynamicColor(light: clashRGB(0x6E6E73), dark: clashRGB(0x98989F)))
    static let textOnAccent = Color(nsColor: clashRGB(0xFFFFFF))

    // MARK: 语义色（强调色跟随系统；数据色不跟随）

    static var accent: Color { Color(nsColor: .controlAccentColor) }
    static let success = Color(nsColor: clashDynamicColor(light: clashRGB(0x1E8E3E), dark: clashRGB(0x30D158)))
    static let warning = Color(nsColor: clashDynamicColor(light: clashRGB(0xB25000), dark: clashRGB(0xFFD60A)))
    static let error = Color(nsColor: clashDynamicColor(light: clashRGB(0xD70015), dark: clashRGB(0xFF453A)))

    static let latencyOk = Color(nsColor: clashDynamicColor(light: clashRGB(0xA07A00), dark: clashRGB(0xFFD60A)))
    static let latencySlow = Color(nsColor: clashDynamicColor(light: clashRGB(0xB25000), dark: clashRGB(0xFF9F0A)))

    static let trafficDown = Color(nsColor: clashDynamicColor(light: clashRGB(0x007AFF), dark: clashRGB(0x0A84FF)))
    static let trafficUp = Color(nsColor: clashDynamicColor(light: clashRGB(0x30B0C7), dark: clashRGB(0x40C8E0)))
}

// MARK: - 字体（系统字体，固定字号，不接 Dynamic Type）
//
// 只有四档：11 / 12 / 13 / 15；标题用 semibold，数字全部等宽。
// 中文不收紧字距（会挤压笔画），只有数字与拉丁字母随字号收紧。

@MainActor
enum Typography {
    /// 15 / semibold —— 二级页面标题（面包屑）
    static let pageTitle = Font.system(size: 15, weight: .semibold)
    /// 13 / semibold —— 卡片头、选中节点名
    static let title = Font.system(size: 13, weight: .semibold)
    /// 13 / regular —— 节点名、磁贴标题、设置行
    static let body = Font.system(size: 13, weight: .regular)
    /// 11 / semibold —— 区块标题、图例
    static let section = Font.system(size: 11, weight: .semibold)
    /// 11 / regular —— 副标题、单位、说明
    static let caption = Font.system(size: 11, weight: .regular)
    /// 12 / medium + 等宽数字 —— 延迟、行内速率
    static let number = Font.system(size: 12, weight: .medium).monospacedDigit()
    /// 11 / medium + 等宽数字 —— 订阅磁贴用量（153pt 宽里的极限）
    static let captionNumber = Font.system(size: 11, weight: .medium).monospacedDigit()
    /// 13 / medium + 等宽数字 —— 状态条速率
    static let numberLarge = Font.system(size: 13, weight: .medium).monospacedDigit()
    /// 13 / medium —— 状态条文案
    static let status = Font.system(size: 13, weight: .medium)
}

// MARK: - 间距阶梯（全项目只准用这些值）
//
// 面板左右外边距与 2×2 磁贴的 153 + 10 是几何锁定，不在阶梯内调整。

@MainActor
enum Space {
    /// 图标与文字、行内微调
    static let hair: CGFloat = 2
    /// 标签与其控件
    static let xs: CGFloat = 4
    /// 行内元素之间
    static let s: CGFloat = 6
    /// 磁贴之间
    static let m: CGFloat = 8
    /// 卡片内边距、卡片之间
    static let l: CGFloat = 12
    /// 区块之间（状态条 → 磁贴 → 曲线 → 策略组）
    static let xl: CGFloat = 16
    /// 面板内主要分区
    static let xxl: CGFloat = 20
}

// MARK: - 尺寸（§2.7 / §3.2）

@MainActor
enum Metrics {
    // 面板
    static let panelWidth: CGFloat = 340
    /// 面板左右外边距：几何锁定（153 + 10 + 153 + 12×2 = 340）
    static let panelPadding: CGFloat = Space.l
    /// 双卡满态自然高度（上限 680）
    static let panelHeight: CGFloat = 678
    /// 内容高度上限
    static let panelHeightMax: CGFloat = 680

    // 分区
    static let statusBarHeight: CGFloat = 36
    static let controlHeight: CGFloat = 138
    /// 状态条 / 主控 / 曲线 / 分组之间的区块间距
    static let sectionGap: CGFloat = Space.xl
    static let chartCardHeight: CGFloat = 80
    static let chartHeight: CGFloat = 36
    static let chartPadding: CGFloat = Space.l
    static let groupTitleHeight: CGFloat = 28
    static let groupCardHeight: CGFloat = 136
    /// 双卡满态：28 + 136 + 12 + 136
    static let groupSectionFullHeight: CGFloat = 312
    static let emptyGroupCardHeight: CGFloat = 132
    static let footerHeight: CGFloat = 32
    static let bannerHeight: CGFloat = 36
    /// banner 与上下内容的间距
    static let bannerSpacing: CGFloat = Space.m
    /// banner 连同上下间距一起占的高度：出现在固定头部，从分组区扣
    static var bannerBlockHeight: CGFloat { bannerHeight + bannerSpacing * 2 }

    // 磁贴与行
    static let tileWidth: CGFloat = 153
    static let tileHeight: CGFloat = 64
    /// 几何锁定：153 + 10 + 153 + 24 = 340
    static let tileGap: CGFloat = 10
    /// 订阅磁贴用量条高度（§4.2）：条只做辅助，数字永远同时给出
    static let tileMeterHeight: CGFloat = 3
    static let segmentHeight: CGFloat = 28
    static let cardHeaderHeight: CGFloat = 32
    static let rowHeight: CGFloat = 32
    /// 二级列表行高（比一级卡片松一档）
    static let listRowHeight: CGFloat = 48
    /// 设置页表单行高
    static let formRowHeight: CGFloat = 36
    static let breadcrumbHeight: CGFloat = 40
    static let cardPadding: CGFloat = Space.l
    /// 卡片上下内边距：卡头 hover 胶囊距卡顶 = 4 + 2 = 6pt
    static let cardInsetV: CGFloat = 4
    /// 一级卡片 hover / 选中胶囊：左右 6、上下 2（32pt 行 → 胶囊 28，文字距胶囊边 4）
    static let pillInsetH: CGFloat = 6
    static let pillInsetV: CGFloat = 2
    /// 二级列表（48pt 行）胶囊：上下 4（行高更高，胶囊更厚）
    static let listPillInsetV: CGFloat = 4

    // 圆角（面板 16 / 卡片 12 / 行 7 / 控件 6）
    static let radiusPanel: CGFloat = 16
    static let radiusCard: CGFloat = 12
    static let radiusRow: CGFloat = 7
    static let radiusTrack: CGFloat = 7
    static let radiusControl: CGFloat = 6

    /// 控件最小命中区
    static let hitTarget: CGFloat = 28

    /// 1px = 1 / displayScale
    static let hairline: CGFloat = 1 / max(2, NSScreen.main?.backingScaleFactor ?? 2)
    /// 卡片 / 磁贴描边：固定 1pt（2x 下 2px，连续），不用 0.5pt
    static let cardStroke: CGFloat = 1

    /// 分组区高度：区块标题 28 + N 张卡 + 卡间 12
    static func groupSectionHeight(forCards count: Int) -> CGFloat {
        let cards = CGFloat(max(count, 0))
        let gaps = CGFloat(max(count - 1, 0)) * Space.l
        return groupTitleHeight + cards * groupCardHeight + gaps
    }
}
