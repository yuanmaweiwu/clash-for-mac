import SwiftUI

/// 状态栏图标：SF Symbol 近似 §4.1 的四种语义，模板色，只有异常态允许一个红点。
@MainActor
struct MenuBarStatusLabel: View {
    let model: PrototypeModel

    private var symbolName: String {
        switch model.status {
        case .proxying, .failed: "power.circle.fill"
        case .idle, .starting, .ready, .direct: "power.circle"
        }
    }

    private var showsSlash: Bool {
        switch model.status {
        case .idle, .starting: true
        case .ready, .proxying, .direct, .failed: false
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .regular))
                .symbolRenderingMode(.monochrome)

            if showsSlash {
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 16, height: 1)
                    .rotationEffect(.degrees(-45))
            }

            if model.status == .failed {
                Circle()
                    .fill(Theme.error)
                    .frame(width: 4, height: 4)
                    .offset(x: 2, y: 1)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel("Clash")
        .accessibilityValue(model.status.title)
        .accessibilityHint("打开控制面板")
    }
}
