import SwiftUI

/// 规则 / 全局 / 直连分段：点击即切换、选中段位移、←/→ 可切（§4.3）。
@MainActor
struct SegmentBarView: View {
    let selection: ProxyMode
    let onSelect: (ProxyMode) -> Void

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var hoveredMode: ProxyMode?

    private var selectionAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.15)
            : .spring(response: 0.28, dampingFraction: 0.80)
    }

    var body: some View {
        track
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay { focusRing }
            .onKeyPress(.leftArrow) {
                move(-1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                move(1)
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("代理模式")
            .accessibilityValue(selection.title)
            .accessibilityHint("左右方向键切换")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(1)
                case .decrement: move(-1)
                @unknown default: break
                }
            }
    }

    private var track: some View {
        HStack(spacing: 0) {
            ForEach(ProxyMode.allCases) { mode in
                segmentButton(for: mode)
            }
        }
        .padding(Space.xs)
        .frame(height: Metrics.segmentHeight)
        .background {
            RoundedRectangle(cornerRadius: Metrics.radiusTrack, style: .continuous)
                .fill(Theme.track)
        }
        .animation(selectionAnimation, value: selection)
    }

    @ViewBuilder
    private var focusRing: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: Metrics.radiusTrack + 2, style: .continuous)
                .strokeBorder(Theme.focus, lineWidth: 2)
                .padding(-2)
        }
    }

    private func segmentButton(for mode: ProxyMode) -> some View {
        Button {
            onSelect(mode)
        } label: {
            segmentLabel(for: mode)
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func segmentLabel(for mode: ProxyMode) -> some View {
        let isSelected = mode == selection
        let isHovered = hoveredMode == mode

        return Text(mode.title)
            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected || isHovered ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .background { selectedBackground(for: mode) }
            .onHover { hovering in
                hoveredMode = hovering ? mode : (hoveredMode == mode ? nil : hoveredMode)
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private func selectedBackground(for mode: ProxyMode) -> some View {
        if mode == selection {
            if reduceMotion {
                selectedPill
            } else {
                selectedPill.matchedGeometryEffect(id: "segmentPill", in: pill)
            }
        }
    }

    private var selectedPill: some View {
        RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
            .fill(Theme.opaque)
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: Metrics.hairline)
            }
    }

    private func move(_ delta: Int) {
        let all = ProxyMode.allCases
        guard let index = all.firstIndex(of: selection) else { return }
        let next = (index + delta + all.count) % all.count
        onSelect(all[next])
    }
}
