import SwiftUI

/// 订阅磁贴（§4.2）：纯导航。153×64，内容区 133pt。
///
/// 排布（用户口径，2026-11）：
/// - 左上：当前激活的 profile 名（单行尾部截断）；右上：库内条数徽标（> 1 才有）
/// - 底部：`到期（9pt）` 左、`用量（10pt 等宽）` 右，同一行
/// - 最下：满宽度 3pt 用量条（左右各 10pt 内边距内）
/// - 缺 `expire` → 左侧留白，用量照常右对齐；缺用量 → 只留商家名；空库 → 只显示「未添加」
///
/// 用量条是**数据可视化**（§8.5 的例外）：3pt、`surface/track` + `accent`，
/// 只做辅助判断，数字永远同时给出，不靠颜色或长度单独承载信息。
@MainActor
struct SubscriptionTileView: View {
    let content: SubscriptionTileContent
    let action: () -> Void

    /// 卡片上下呼吸区：10pt（与左右内边距同值，四边留白一致）
    private static let verticalInset: CGFloat = Metrics.cardPadding
    /// 用量行与条之间的间距
    private static let meterSpacing: CGFloat = 4

    var body: some View {
        TileShell(label: "订阅", value: content.accessibilityValue, action: action) {
            VStack(alignment: .leading, spacing: 0) {
                nameRow

                Spacer(minLength: 2)

                // 有到期或有用量就画数据行；只有用量才画条（到期单独存在时也应当可见）
                if content.quotaText != nil || content.expiryText != nil {
                    metaRow(content.quotaText, fraction: content.usageFraction)
                    if let fraction = content.usageFraction {
                        meter(fraction, fill: usageColors(fraction).fill)
                            .padding(.top, Self.meterSpacing)
                    }
                }
            }
            .padding(.vertical, Self.verticalInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityHint(Text("按下打开订阅管理"))
    }

    // MARK: - 行

    /// 第 1 行：商家名 + 右上角条数徽标（徽标不吃名字的宽度优先级）
    private var nameRow: some View {
        HStack(spacing: 4) {
            Text(content.name ?? "未添加")
                .font(Typography.body)
                .foregroundStyle(content.name == nil ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if content.badgeCount > 1 {
                countBadge
            }
        }
    }

    /// 第 2 行：左到期 / 右用量。缺 `expire` 时左侧留白，用量仍然右对齐；只有其中一个也照常显示。
    private func metaRow(_ quotaText: String?, fraction: Double?) -> some View {
        HStack(spacing: 4) {
            if let expiry = content.expiryText {
                Text(expiry)
                    .font(Typography.caption)
                    .foregroundStyle(content.isExpired ? Theme.error : Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let quotaText {
                Text(quotaText)
                    .font(Typography.captionNumber)
                    .foregroundStyle(usageColors(fraction ?? 0).text)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    // MARK: - 用量条与配色

    /// 满宽度 3pt 用量条：track `surface/track`，fill 按用量转 warning / error，长度按 100% 封顶
    private func meter(_ fraction: Double, fill: Color) -> some View {
        Capsule(style: .continuous)
            .fill(Theme.track)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.tileMeterHeight)
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(fill)
                    .scaleEffect(x: min(max(fraction, 0), 1), anchor: .leading)
            }
            .accessibilityHidden(true)
    }

    /// 用量色阶（§4.2）：≥100% `error`，>90% `warning`，其余 `accent` / 正文色
    private func usageColors(_ fraction: Double) -> (fill: Color, text: Color) {
        if fraction >= 1 { return (Theme.error, Theme.error) }
        if fraction > 0.9 { return (Theme.warning, Theme.warning) }
        return (Theme.accent, Theme.textPrimary)
    }

    private var countBadge: some View {
        Text("\(content.badgeCount)")
            .font(Typography.captionNumber)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 14)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.track)
            }
            .accessibilityHidden(true)
    }
}

#if DEBUG
// 五种状态夹具：正常 / 快用尽 / 已过期 / 真实订阅（机场A：100.8/128 GB，无 expire）/ 未导入。
// 全部走生产的 `tileContent` 格式化，不是手写的假字符串。
#Preview("订阅磁贴 · 五种状态") {
    Grid(alignment: .leading, horizontalSpacing: Metrics.tileGap, verticalSpacing: 10) {
        GridRow {
            tilePreviewCell("正常 · 42%", tilePreviewContent())
            tilePreviewCell("快用尽 · 93%", tilePreviewContent(download: 128_000_000_000))
        }
        GridRow {
            tilePreviewCell("已过期", tilePreviewContent(download: 128_000_000_000, expireOffset: -10 * 86_400))
            tilePreviewCell("机场A · 无到期", tilePreviewContent(download: 108_233_273_344, expireOffset: nil))
        }
        GridRow {
            tilePreviewCell("未导入", .empty)
            Color.clear
        }
    }
    .padding(Metrics.panelPadding)
}

@MainActor
private func tilePreviewCell(_ title: String, _ content: SubscriptionTileContent) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title)
            .font(Typography.caption)
            .foregroundStyle(Theme.textSecondary)
        SubscriptionTileView(content: content) {}
    }
}

/// 夹具：默认 53.8/128 GB（约 42%）+ 40 天后到期 + 库内 3 条
@MainActor
private func tilePreviewContent(
    download: Int? = 57_783_820_288,
    total: Int? = 137_438_953_472,
    expireOffset: TimeInterval? = 40 * 86_400
) -> SubscriptionTileContent {
    let expire = expireOffset.map { Int(Date.now.addingTimeInterval($0).timeIntervalSince1970) }
    let entry = ProfileEntry(
        id: "preview",
        name: "机场 A",
        source: ProfileSource(kind: .url),
        subscriptionInfo: ProfileSubscriptionInfo(download: download, total: total, expire: expire)
    )
    return entry.tileContent(badgeCount: 3)
}
#endif
