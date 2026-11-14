import SwiftUI

/// 规则行 40pt（§4.11）：类型徽标 + payload + 行尾目标。
///
/// 徽标按内容宽度（左右 4pt 内边距）：短类型（`DOMAIN` / `MATCH` / `GEOIP`）就该比
/// `DOMAIN-KEYWORD` 短，不强行拉齐列宽；底色仍是每行都有的整块 `surface/track`。
/// 徽标与正文之间固定 8pt（`HStack(spacing:)`），不贴住。
/// 行不可点（没有选中 / 执行语义）：hover 不加底色，避免暗示能操作。
/// payload 中间截断（域名前后段都有信息），行尾目标只 hug 文本、上限 104 尾部截断。
@MainActor
struct RuleRowView: View {
    let rule: RuleEntry

    var body: some View {
        HStack(spacing: Space.m) {
            Text(rule.canonicalType)
                .font(.system(size: 11, weight: .medium).monospaced())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, Space.xs)
                .frame(height: Metrics.ruleBadgeHeight)
                .background {
                    RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                        .fill(Theme.track)
                }
                .fixedSize(horizontal: true, vertical: false)

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
