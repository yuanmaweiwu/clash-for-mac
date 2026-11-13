#!/usr/bin/env swift
//
//  make-icon.swift
//  Clash — App 图标生成脚本
//
//  ⚠️ 这是**生成脚本**：图标不要手改。
//     `Clash/Resources/Assets.xcassets/AppIcon.appiconset/` 里的 PNG 与 Contents.json
//     全部由本脚本产出，任何手改都会在下次运行时被覆盖。
//     要改图标：改本文件的几何 / 颜色常量，然后重新运行。
//
//  用法（仓库根目录）：
//      swift Scripts/make-icon.swift
//      swift Scripts/make-icon.swift --preview-only   # 只出 1024 预览，不写图标集
//
//  设计口径（与面板一致：控制中心式单色几何 + 一个强调色）
//     底       #1C1C1E 深灰近黑（对齐 Theme.opaque 的深色侧 #1E1E20 语感）
//     强调色   #0A84FF（Theme.accent 深色侧）
//     图形     `power` 符号（与总开关磁贴 / 状态栏同源）：圆环 + 顶部竖笔，缺口朝上
//     线宽     内容（power 符号外径）的 8%
//     留白     squircle 本体占画布 80.5%，其余透明（符合 Apple 图标网格）
//     禁止     文字、渐变、玻璃高光、投影、多层叠色——纯平色块
//
//  实现：CoreGraphics + ImageIO，无第三方依赖。
//  幂等：重复运行只会覆写同样的 10 个 PNG + Contents.json，不追加、不留残余。
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 设计常量（要调图标只改这里）

/// 画布边长（母版，其余尺寸由它等比降采样）
let masterSize = 1024

/// squircle 本体相对画布的占比。Apple macOS 图标网格：1024 画布下本体约 824，
/// 即四周各留 100（≈9.8%）。
let bodyRatio: CGFloat = 824.0 / 1024.0

/// 超椭圆指数。Apple 的连续曲率圆角（squircle）用 5 次超椭圆近似足够贴合。
let squircleExponent: CGFloat = 5.0

/// power 符号外径相对画布的占比（决定图标视觉重量）。
let glyphRatio: CGFloat = 0.52

/// 线宽相对 power 符号外径的占比：8%。
let strokeRatio: CGFloat = 0.08

/// 缺口总角度（居中朝上）
let gapDegrees: CGFloat = 48

/// 颜色（sRGB）
let backgroundHex: UInt32 = 0x1C1C1E
let accentHex: UInt32 = 0x0A84FF

// MARK: - 输出位置

let filePath = #filePath
let scriptURL = filePath.hasPrefix("/")
    ? URL(fileURLWithPath: filePath)
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let catalogURL = repoRoot.appendingPathComponent("Clash/Resources/Assets.xcassets")
let iconSetURL = catalogURL.appendingPathComponent("AppIcon.appiconset")

/// macOS 图标槽位：像素边长 + 文件名（1x / 2x 命名齐全）
struct Slot {
    let pixels: Int
    let filename: String
    let size: String
    let scale: String
}

let slots: [Slot] = [
    Slot(pixels: 16, filename: "icon_16x16.png", size: "16x16", scale: "1x"),
    Slot(pixels: 32, filename: "icon_16x16@2x.png", size: "16x16", scale: "2x"),
    Slot(pixels: 32, filename: "icon_32x32.png", size: "32x32", scale: "1x"),
    Slot(pixels: 64, filename: "icon_32x32@2x.png", size: "32x32", scale: "2x"),
    Slot(pixels: 128, filename: "icon_128x128.png", size: "128x128", scale: "1x"),
    Slot(pixels: 256, filename: "icon_128x128@2x.png", size: "128x128", scale: "2x"),
    Slot(pixels: 256, filename: "icon_256x256.png", size: "256x256", scale: "1x"),
    Slot(pixels: 512, filename: "icon_256x256@2x.png", size: "256x256", scale: "2x"),
    Slot(pixels: 512, filename: "icon_512x512.png", size: "512x512", scale: "1x"),
    Slot(pixels: 1024, filename: "icon_512x512@2x.png", size: "512x512", scale: "2x"),
]

// MARK: - 颜色工具

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(colorSpace: sRGB, components: [r, g, b, alpha])!
}

// MARK: - 几何

/// 5 次超椭圆（squircle）。采样点数按画布尺寸给足，1024 下无可见折线。
func squirclePath(in rect: CGRect, exponent n: CGFloat) -> CGPath {
    let a = rect.width / 2
    let b = rect.height / 2
    let cx = rect.midX
    let cy = rect.midY
    let e = 2 / n
    let samples = 2048
    let path = CGMutablePath()

    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let ct = cos(t)
        let st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), e)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), e)
        if i == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

// MARK: - 绘制

func makeBitmapContext(pixels: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("无法创建 \(pixels)px 位图上下文")
    }
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

/// 母版 1024：透明底 + 深灰 squircle + 强调色 power 符号（无描边、无阴影、无渐变）。
func makeMaster() -> CGImage {
    let s = CGFloat(masterSize)
    let ctx = makeBitmapContext(pixels: masterSize)

    // 1. 透明画布（不填充）
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // 2. squircle 本体
    let inset = s * (1 - bodyRatio) / 2
    let bodyRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    ctx.addPath(squirclePath(in: bodyRect, exponent: squircleExponent))
    ctx.setFillColor(color(backgroundHex))
    ctx.fillPath()

    // 3. power 符号：圆环（缺口朝上）+ 顶部竖笔
    let cx = s / 2
    let cy = s / 2
    let glyphOuter = s * glyphRatio
    let stroke = glyphOuter * strokeRatio
    let outerRadius = glyphOuter / 2
    let ringRadius = outerRadius - stroke / 2 // 描边中线半径，保证外径 = glyphOuter

    ctx.setStrokeColor(color(accentHex))
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let halfGap = gapDegrees / 2 * .pi / 180
    ctx.addArc(
        center: CGPoint(x: cx, y: cy),
        radius: ringRadius,
        startAngle: .pi / 2 + halfGap,
        endAngle: .pi / 2 - halfGap + 2 * .pi,
        clockwise: false
    )
    ctx.strokePath()

    // 竖笔：从圆心向上，圆头收口正好落在圆环外沿
    ctx.move(to: CGPoint(x: cx, y: cy))
    ctx.addLine(to: CGPoint(x: cx, y: cy + ringRadius))
    ctx.strokePath()

    guard let image = ctx.makeImage() else { fatalError("母版位图导出失败") }
    return image
}

/// 等比降采样：逐级减半，避免一次 64 倍缩放带来的振铃 / 锯齿。
func resized(_ image: CGImage, to pixels: Int) -> CGImage {
    var current = image
    var size = image.width
    while size > pixels {
        let next = max(pixels, size / 2)
        let ctx = makeBitmapContext(pixels: next)
        ctx.interpolationQuality = .high
        ctx.draw(current, in: CGRect(x: 0, y: 0, width: next, height: next))
        guard let scaled = ctx.makeImage() else { fatalError("降采样到 \(next)px 失败") }
        current = scaled
        size = next
    }
    return current
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("无法写入 \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("PNG 编码失败：\(url.path)")
    }
}

// MARK: - 产物元数据

func contentsJSON() -> String {
    var entries: [String] = []
    for slot in slots {
        entries.append(
            """
                {
                  "filename" : "\(slot.filename)",
                  "idiom" : "mac",
                  "scale" : "\(slot.scale)",
                  "size" : "\(slot.size)"
                }
            """
        )
    }
    return """
    {
      "images" : [
    \(entries.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
}

func writeIfChanged(_ text: String, to url: URL) {
    let data = Data(text.utf8)
    if let existing = try? Data(contentsOf: url), existing == data { return }
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        fatalError("写入失败 \(url.path): \(error)")
    }
}

// MARK: - 主流程

let fm = FileManager.default
let previewOnly = CommandLine.arguments.contains("--preview-only")

let master = makeMaster()

if previewOnly {
    let previewURL = repoRoot.appendingPathComponent("icon-preview-1024.png")
    writePNG(master, to: previewURL)
    print("预览：\(previewURL.path)")
    exit(0)
}

try? fm.createDirectory(at: iconSetURL, withIntermediateDirectories: true)

// 图标集根 Contents.json（已存在且内容正确时不改）
let catalogContents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
writeIfChanged(catalogContents, to: catalogURL.appendingPathComponent("Contents.json"))

var written: [(String, Int)] = []
for slot in slots {
    let image = slot.pixels == masterSize ? master : resized(master, to: slot.pixels)
    let url = iconSetURL.appendingPathComponent(slot.filename)
    writePNG(image, to: url)
    written.append((slot.filename, slot.pixels))
}

writeIfChanged(contentsJSON(), to: iconSetURL.appendingPathComponent("Contents.json"))

print("App 图标已生成 → \(iconSetURL.path)")
for (name, px) in written {
    print("  • \(name)  \(px)×\(px)")
}
print("共 \(written.count) 个 PNG + Contents.json（生成脚本：Scripts/make-icon.swift，图标不要手改）")
