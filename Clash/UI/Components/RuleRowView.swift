import SwiftUI

/// 规则行 40pt（§4.11）：类型徽标 + payload + 行尾目标。
///
/// 徽标是**定宽列**（104pt）：payload 左缘每行落在同一条竖线上，500+ 行扫读不锯齿；
/// 徽标底是 104×18 的整块 `surface/track`（不随类型长短伸缩），所以短类型也不会「看起来没有底」。
/// 行不可点（没有选中 / 执行语义）：hover 不加底色，避免暗示能操作。
/// payload 中间截断（域名前后段都有信息），行尾目标尾部截断。
@MainActor
struct RuleRowView: View {
    let rule: RuleEntry

    var body: some View {
        HStack(spacing: Space.m) {
            Text(rule.canonicalType)
                .font(.system(size: 11, weight: .medium).monospaced())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, Space.xs)
                .frame(
                    width: Metrics.ruleBadgeColumnWidth,
                    height: Metrics.ruleBadgeHeight,
                    alignment: .leading
                )
                .background {
                    RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                        .fill(Theme.track)
                }

            Text(rule.payload)
                .font(Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(rule.proxy)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: Metrics.ruleTargetMaxWidth, alignment: .trailing)
                // 目标列只 hug 文本（上限 104）：不 hug 的话 HStack 会把它撑满 104，
                // payload 只剩 ~68pt，「192.168.0.0/16」这种短串也会被截。
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: Metrics.ruleRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(rule.canonicalType)，\(rule.payload)，\(rule.proxy)"))
    }
}
