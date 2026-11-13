import SwiftUI

/// 连接列表的一行 48pt：host + 副行（进程 · 规则 · 节点），行尾速率与 hover 关闭按钮。
///
/// 行本身不可点（没有选中语义）；只有 hover 出现的 `xmark.circle.fill` 是操作。
@MainActor
struct ConnectionRowView: View {
    let entry: ConnectionEntry
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(displayHost)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // 两块文字合成一个无障碍元素；关闭按钮仍是独立元素
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityValue(Text(accessibilityValue))

            Spacer(minLength: Space.s)

            Text(trafficText)
                .font(Typography.number)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()

            // 始终占位，hover 才显示：速率文字不因出现 / 消失而左右跳
            closeButton
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.listRowHeight)
        .background { hoverPill }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }

    private var displayHost: String {
        entry.host.isEmpty ? "未知地址" : entry.host
    }

    /// 副行：`进程 · 规则 · 节点`，缺项直接跳过（不补占位）
    private var subtitle: String {
        [entry.processName, entry.rule, entry.node]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// 内核只给每条连接的累计字节，没有逐连接速率，这里按累计量展示（不编造 `/s`）
    private var trafficText: String {
        "↑ \(TrafficFormat.bytes(entry.upload)) ↓ \(TrafficFormat.bytes(entry.download))"
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: Metrics.hitTarget, height: Metrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("关闭这条连接"))
    }

    @ViewBuilder
    private var hoverPill: some View {
        if isHovering {
            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                .fill(Theme.rowHover)
                .padding(.horizontal, Metrics.pillInsetH)
                .padding(.vertical, Metrics.listPillInsetV)
        }
    }

    private var accessibilityLabel: String {
        var parts = [displayHost]
        if let process = entry.processName { parts.append(process) }
        parts.append(entry.rule.isEmpty ? "规则未知" : "规则 \(entry.rule)")
        return parts.joined(separator: "，")
    }

    private var accessibilityValue: String {
        "上传 \(TrafficFormat.spokenBytes(entry.upload))，下载 \(TrafficFormat.spokenBytes(entry.download))"
    }
}
