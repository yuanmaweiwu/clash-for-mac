import SwiftUI

/// 主控区下方的一行微文案：**系统代理与 TUN 是替代关系**（`docs/02-UI-SPEC.md` §4.2）。
///
/// 两个磁贴并排时容易被读成「两个都要开」。这一行只在**两者都未启用**时露字，
/// 一句「任选其一」把互斥讲清楚，不新增区块。
///
/// 高度恒定（留白由 `Metrics.transportHintHeight` 锁定）：显字 / 隐字不改变面板高度，
/// 否则开代理的瞬间窗口会矮一截。隐字时也退出无障碍树，免得 VoiceOver 读到看不见的提示。
@MainActor
struct TransportHintView: View {
    let isVisible: Bool

    var body: some View {
        Text("系统代理与 TUN 任选其一")
            .font(Typography.caption)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.transportHintTextHeight)
            .padding(.top, Space.s)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.16), value: isVisible)
            .accessibilityHidden(!isVisible)
    }
}
