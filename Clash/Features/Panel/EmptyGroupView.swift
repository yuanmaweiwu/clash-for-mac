import SwiftUI

/// 空态占位卡 120pt：`tray` + 一句说明（§7）。
///
/// 两种形态：
/// - 没导入订阅：`body` 文案 + 「导入订阅」按钮（v1 只支持链接导入，不再提供本地 YAML）
/// - 已导入订阅（内核还没就绪 / 配置里没有策略组）：只有一句 `caption` 说明，不给导入按钮，
///   否则用户会以为自己的订阅没导进来
@MainActor
struct EmptyGroupView: View {
    /// 空态主文案：无配置「还没有配置」/ 有配置但无策略组「当前配置没有策略组」/ 内核未就绪「内核未运行」
    var title = "还没有配置"
    /// 是否展示「导入订阅」：只有真的没导入订阅时才展示
    var showsImportActions = true

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.textTertiary)

            Text(title)
                .font(showsImportActions ? Typography.body : Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            if showsImportActions {
                HStack(spacing: Space.l) {
                    Text("导入订阅")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textOnAccent)
                        .padding(.horizontal, Space.l)
                        .frame(height: Metrics.hitTarget)
                        .background {
                            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                                .fill(Theme.accent)
                        }
                }
                .padding(.top, Space.hair)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .background {
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .fill(Theme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: Metrics.cardStroke)
                }
                .compositingGroup()
        }
        .accessibilityElement(children: .combine)
    }
}
