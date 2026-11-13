import SwiftUI

/// 订阅磁贴（§4.2）：纯导航，四行 = 标题 / 名称 / 用量 / 到期。
///
/// 排版（153×64，内容区 133pt）：13 标题 15.3 + 11 名称 13.0 + 10 用量 11.8 + 9 到期 10.6，
/// 行距 2 × 3 = 6，合计 56.7pt，上下各留 3.7 —— 固定高度不随内容变。
///
/// 用量条是**数据可视化**（§8.5 的例外）：3pt、`surface/track` + `accent`，
/// 只做辅助判断，数字永远同时给出，不靠颜色或长度单独承载信息。
@MainActor
struct SubscriptionTileView: View {
    let content: SubscriptionTileContent
    let action: () -> Void

    /// 行距 2pt：四行加起来才塞得进 64pt
    private static let rowSpacing: CGFloat = 2

    var body: some View {
        TileShell(label: "订阅", value: content.accessibilityValue, action: action) {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                titleRow
                nameRow

                if let quotaText = content.quotaText, let fraction = content.usageFraction {
                    quotaRow(quotaText, fraction: fraction)
                }

                if let expiry = content.expiryText {
                    Text(expiry)
                        .font(Typography.micro)
                        .foregroundStyle(content.isExpired ? Theme.error : Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityHint(Text("按下打开订阅管理"))
    }

    // MARK: - 四行

    /// 第 1 行：标题 + 右上角条数徽标（同一行，避免和密集内容抢位置）
    private var titleRow: some View {
        HStack(spacing: 4) {
            Text("订阅")
                .font(Typography.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 4)
            if content.badgeCount > 1 {
                countBadge
            }
        }
    }

    /// 第 2 行：当前激活的 profile 名（中间截断，保留首尾便于辨认机场）
    private var nameRow: some View {
        HStack(spacing: 3) {
            Text(content.name ?? "未添加")
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// 第 3 行：用量数字 + 3pt 条（数字在左，条吃满剩余宽度）
    private func quotaRow(_ text: String, fraction: Double) -> some View {
        let colors = usageColors(fraction)
        return HStack(spacing: 6) {
            Text(text)
                .font(Typography.numberSmall)
                .foregroundStyle(colors.text)
                .lineLimit(1)
                .fixedSize()

            meter(fraction, fill: colors.fill)
        }
    }

    // MARK: - 用量条与配色

    /// 3pt 用量条：track `surface/track`，fill 按用量转 warning / error
    private func meter(_ fraction: Double, fill: Color) -> some View {
        Capsule(style: .continuous)
            .fill(Theme.track)
            .frame(height: Metrics.tileMeterHeight)
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(fill)
                    .scaleEffect(x: min(max(fraction, 0), 1), anchor: .leading)
            }
            .accessibilityHidden(true)
    }

    /// 用量色阶（§4.2）：≥100% `error`，>90% `warning`，其余 `accent`
    private func usageColors(_ fraction: Double) -> (fill: Color, text: Color) {
        if fraction >= 1 { return (Theme.error, Theme.error) }
        if fraction > 0.9 { return (Theme.warning, Theme.warning) }
        return (Theme.accent, Theme.textPrimary)
    }

    private var countBadge: some View {
        Text("\(content.badgeCount)")
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
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
// 五种状态夹具：正常 / 快用尽 / 已过期 / 真实订阅（机场A：100.4/128 GB，无 expire）/ 未导入。
// 全部走生产的 `tileContent` 格式化，不是手写的假字符串。
#Preview("订阅磁贴 · 五种状态") {
    Grid(alignment: .leading, horizontalSpacing: Metrics.tileGap, verticalSpacing: 10) {
        GridRow {
            tilePreviewCell("正常 · 42%", tilePreviewContent())
            tilePreviewCell("快用尽 · 93%", tilePreviewContent(download: 128_000_000_000))
        }
        GridRow {
            tilePreviewCell("已过期", tilePreviewContent(download: 128_000_000_000, expireOffset: -10 * 86_400))
            tilePreviewCell("机场A · 无到期", tilePreviewContent(download: 107_803_679_130, expireOffset: nil))
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
            .font(Typography.micro)
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
