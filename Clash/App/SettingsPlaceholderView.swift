import SwiftUI

/// 设置窗口占位：接入 `Features/Settings` 后替换。
@MainActor
struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("设置待实现")
                .font(.headline)
            Text("v0.1 骨架，暂无设置项")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 420, height: 240)
    }
}
