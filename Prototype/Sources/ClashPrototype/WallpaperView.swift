import SwiftUI

/// 模拟桌面壁纸：只为了让面板的材质有可被「透过」的东西，不参与产品视觉。
@MainActor
struct WallpaperView: View {
    let tone: WallpaperTone

    var body: some View {
        switch tone {
        case .light: lightWallpaper
        case .dark: darkWallpaper
        case .solid: Theme.wallpaperSolid
        }
    }

    private var lightWallpaper: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.wallpaperLightTop, Theme.wallpaperLightMid, Theme.wallpaperLightBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Theme.wallpaperLightWarm.opacity(0.55), .clear],
                center: UnitPoint(x: 0.78, y: 0.84),
                startRadius: 8,
                endRadius: 520
            )
            RadialGradient(
                colors: [Theme.wallpaperLightCool.opacity(0.50), .clear],
                center: UnitPoint(x: 0.18, y: 0.16),
                startRadius: 8,
                endRadius: 460
            )
        }
    }

    private var darkWallpaper: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.wallpaperDarkTop, Theme.wallpaperDarkMid, Theme.wallpaperDarkBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Theme.wallpaperDarkCool.opacity(0.55), .clear],
                center: UnitPoint(x: 0.22, y: 0.20),
                startRadius: 8,
                endRadius: 520
            )
            RadialGradient(
                colors: [Theme.wallpaperDarkWarm.opacity(0.45), .clear],
                center: UnitPoint(x: 0.82, y: 0.86),
                startRadius: 8,
                endRadius: 480
            )
        }
    }
}
