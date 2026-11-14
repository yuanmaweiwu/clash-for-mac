import SwiftUI

/// 规则行 40pt（§4.11）：类型徽标 + payload + 行尾目标。
///
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
                .padding(.horizontal, Space.xs)
                .frame(height: Metrics.ruleBadgeHeight)
                .background {
                    RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
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
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(height: Metrics.ruleRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(rule.canonicalType)，\(rule.payload)，\(rule.proxy)"))
    }
}
