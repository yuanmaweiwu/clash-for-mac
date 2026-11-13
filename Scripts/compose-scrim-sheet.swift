import AppKit

// 三档背景对比拼版：两行（浅色 / 深色）× 三列（A / B / C），带标题
let args = CommandLine.arguments
guard args.count >= 8 else {
    print("usage: sheet <out.png> <a-light> <b-light> <c-light> <a-dark> <b-dark> <c-dark>")
    exit(1)
}
let out = args[1]
let paths = Array(args[2...7])

let gap: CGFloat = 24
let headerHeight: CGFloat = 42
let rowLabelHeight: CGFloat = 28
let inset: CGFloat = 28
let images = paths.map { NSImage(contentsOfFile: $0)! }
let cell = images[0].size

let width = inset * 2 + cell.width * 3 + gap * 2
let height = inset * 2 + headerHeight + (rowLabelHeight + cell.height) * 2 + gap

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

let titles = ["A  轻透", "B  中等（推荐）", "C  实底"]
let rows = ["浅色模式", "深色模式"]

func draw(_ text: String, at point: NSPoint, size: CGFloat, bold: Bool) {
    let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1)]
    (text as NSString).draw(at: point, withAttributes: attrs)
}

let headerY = height - inset - headerHeight + 12
for col in 0..<3 {
    draw(titles[col], at: NSPoint(x: inset + (cell.width + gap) * CGFloat(col), y: headerY), size: 15, bold: true)
}

var imageTop = height - inset - headerHeight - rowLabelHeight
for row in 0..<2 {
    draw(rows[row], at: NSPoint(x: inset, y: imageTop + 6), size: 13, bold: false)
    let imageY = imageTop - cell.height
    for col in 0..<3 {
        let x = inset + (cell.width + gap) * CGFloat(col)
        images[row * 3 + col].draw(
            in: NSRect(x: x, y: imageY, width: cell.width, height: cell.height),
            from: .zero, operation: .sourceOver, fraction: 1
        )
    }
    imageTop = imageY - gap - rowLabelHeight
}

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: out))
print(out)
