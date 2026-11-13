import Foundation

/// 模拟桌面壁纸的三档（原型专用，不是产品 token）。
enum WallpaperTone: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "浅"
        case .dark: "深"
        case .solid: "纯色"
        }
    }
}
