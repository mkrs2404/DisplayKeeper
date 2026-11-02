import AppKit

// Original, geometric artwork. Keep the large icon flat and the menu-bar mark
// legible at its actual 20 × 18 point size.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func png(size: Int, name: String, draw: () -> Void) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}

func drawIcon() {
    let ink = color(0x173F35)
    color(0xE7F0E9).setFill()
    NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 204, yRadius: 204).fill()

    // A single monitor, precisely centered. Three quiet color fields suggest
    // calibration without a literal badge, label or decorative symbol.
    ink.setFill()
    NSBezierPath(roundedRect: NSRect(x: 192, y: 324, width: 640, height: 434), xRadius: 58, yRadius: 58).fill()
    let screen = NSBezierPath(roundedRect: NSRect(x: 224, y: 356, width: 576, height: 370), xRadius: 28, yRadius: 28)
    NSGraphicsContext.saveGraphicsState()
    screen.addClip()
    for (index, shade) in [UInt32(0xC9E6C1), 0x82B69E, 0x3E887A].enumerated() {
        color(shade).setFill()
        NSRect(x: 224 + CGFloat(index) * 192, y: 356, width: 192, height: 370).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    ink.setFill()
    NSBezierPath(roundedRect: NSRect(x: 483, y: 250, width: 58, height: 90), xRadius: 15, yRadius: 15).fill()
    NSBezierPath(roundedRect: NSRect(x: 382, y: 228, width: 260, height: 34), xRadius: 17, yRadius: 17).fill()
}

try png(size: 1024, name: "AppIcon.png", draw: drawIcon)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try png(size: points * scale, name: "AppIcon.iconset/icon_\(points)x\(points)\(suffix).png", draw: drawIcon)
    }
}

// A true template PDF: macOS supplies the light/dark menu-bar tint.
final class MenuMark: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setStroke()
        let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 5.25, width: 17, height: 11.25), xRadius: 2, yRadius: 2)
        frame.lineWidth = 1.35
        frame.stroke()
        let stand = NSBezierPath()
        stand.lineWidth = 1.35; stand.lineCapStyle = .round
        stand.move(to: NSPoint(x: 10, y: 5)); stand.line(to: NSPoint(x: 10, y: 2))
        stand.move(to: NSPoint(x: 6.5, y: 1.75)); stand.line(to: NSPoint(x: 13.5, y: 1.75))
        stand.stroke()
        for x: CGFloat in [5.5, 10, 14.5] {
            let line = NSBezierPath()
            line.lineWidth = 1.7; line.lineCapStyle = .round
            line.move(to: NSPoint(x: x, y: 8.5)); line.line(to: NSPoint(x: x, y: 13))
            line.stroke()
        }
    }
}
let mark = MenuMark(frame: NSRect(x: 0, y: 0, width: 20, height: 18))
try mark.dataWithPDF(inside: mark.bounds).write(to: output.appendingPathComponent("MenuBarTemplate.pdf"))
