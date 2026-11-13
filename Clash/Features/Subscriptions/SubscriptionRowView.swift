import SwiftUI

/// 订阅库的一行 48pt：来源图标 + 名称 + 第二行说明；行尾是状态图标与到期文本（§4.8）。
@MainActor
struct SubscriptionRowView: View {
    let profile: SubscriptionProfile
    let isActive: Bool
    let isUpdating: Bool
    let onActivate: () -> Void
    let onUpdate: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var showsHover: Bool { isHovering }

    var body: some View {
        ZStack(alignment: .leading) {
            Button(action: onActivate) {
                rowBody
            }
            .buttonStyle(PressableButtonStyle())
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: Metrics.radiusRow + 1, style: .continuous)
                        .strokeBorder(Theme.focus, lineWidth: 2)
                        .padding(-1)
                }
            }
            .overlay(alignment: .trailing) { menuButton }

            if isActive { activeBar }
        }
        .frame(height: 48)
        .background { rowBackground }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovering)
        .animation(.easeInOut(duration: 0.18), value: isActive)
    }

    private var rowBody: some View {
        HStack(spacing: 8) {
            Image(systemName: profile.source == .url ? "link" : "doc.text")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(isActive ? Typography.title : Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(isUpdating ? "更新中" : profile.detailText)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            // 行尾：上槽放状态 / 下图右对齐到期文本，与第二行同基线
            VStack(alignment: .trailing, spacing: 2) {
                statusIcon
                    .frame(width: 16, height: 16)

                if let expiry = profile.expiryText {
                    Text(expiry)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                } else {
                    Color.clear.frame(width: 1, height: 13)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 36)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isUpdating {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
        } else if profile.updateFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.warning)
        } else {
            Color.clear
        }
    }

    private var menuButton: some View {
        Menu {
            Button("更新") { onUpdate() }
            Button("切换为当前") { onActivate() }
                .disabled(isActive)
            Button("重命名…") { onRename() }
            Button(isActive ? "删除（将停止内核）" : "删除", role: .destructive) { onDelete() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.trailing, 6)
        .opacity(showsHover ? 1 : 0)
        .allowsHitTesting(showsHover)
        .accessibilityLabel(Text("订阅操作"))
    }

    private var activeBar: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Theme.accent)
            .frame(width: 3, height: 22)
            .padding(.leading, 6)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isActive || showsHover {
            RoundedRectangle(cornerRadius: Metrics.radiusRow, style: .continuous)
                .fill(isActive ? Theme.rowSelected : Theme.rowHover)
                .padding(.horizontal, Metrics.pillInsetH)
                .padding(.vertical, Metrics.listPillInsetV)
        }
    }
}
