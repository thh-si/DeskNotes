import AppKit
import CoreImage

// Draws the DeskNotes app icon in the style of macOS "Liquid Glass": a vivid tile with frosted,
// translucent glass layers (a desk, a note on it, two more notes behind), each with a real blur of
// what lies beneath, a specular highlight, a bright gradient rim and a soft shadow.
// Usage: IconMaker <output-dir>   → <output-dir>/AppIcon.iconset/*.png and <output-dir>/preview.png
// build.sh turns the iconset into Resources/AppIcon.icns with `iconutil`.

func hex(_ value: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha)
}

// MARK: - Drawing state

let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
var pixelScale: CGFloat = 1
let ciContext = CIContext()

var cg: CGContext { NSGraphicsContext.current!.cgContext }

// MARK: - Helpers

func cgPath(_ path: NSBezierPath) -> CGPath {
    let result = CGMutablePath()
    var points = [NSPoint](repeating: .zero, count: 3)
    for i in 0..<path.elementCount {
        switch path.element(at: i, associatedPoints: &points) {
        case .moveTo: result.move(to: points[0])
        case .lineTo: result.addLine(to: points[0])
        case .curveTo: result.addCurve(to: points[2], control1: points[0], control2: points[1])
        case .closePath: result.closeSubpath()
        @unknown default: break
        }
    }
    return result
}

func card(center: NSPoint, size: CGSize, angle: CGFloat = 0, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                                width: size.width, height: size.height),
                            xRadius: radius, yRadius: radius)
    if angle != 0 {
        var transform = AffineTransform()
        transform.translate(x: center.x, y: center.y)
        transform.rotate(byDegrees: angle)
        transform.translate(x: -center.x, y: -center.y)
        path.transform(using: transform)
    }
    return path
}

/// The current drawing, blurred: what a pane of glass in front of it would show.
func blurredBackdrop(radius: CGFloat) -> CGImage? {
    guard let image = cg.makeImage() else { return nil }
    let input = CIImage(cgImage: image)
    let blurred = input.clampedToExtent()
        .applyingGaussianBlur(sigma: Double(radius * pixelScale))
        .cropped(to: input.extent)
    return ciContext.createCGImage(blurred, from: input.extent)
}

/// Soft shadow that falls only outside the shape (the glass itself stays see-through).
func castShadow(_ path: NSBezierPath, blur: CGFloat = 36, offset: CGFloat = 18, alpha: CGFloat = 0.34, color: Int = 0x2A1166) {
    NSGraphicsContext.saveGraphicsState()
    let outside = NSBezierPath(rect: canvas.insetBy(dx: -200, dy: -200))
    outside.append(path)
    outside.windingRule = .evenOdd
    outside.addClip()
    let shadow = NSShadow()
    shadow.shadowColor = hex(color, alpha)
    shadow.shadowOffset = NSSize(width: 0, height: -offset)
    shadow.shadowBlurRadius = blur
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

/// A bright rim along the inside edge: strong on the upper left, fading towards the lower right.
func rim(_ path: NSBezierPath, width: CGFloat, start: CGFloat = 0.95, end: CGFloat = 0.12) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    cg.addPath(cgPath(path))
    cg.setLineWidth(width * 2)
    cg.replacePathWithStrokedPath()
    cg.clip()
    NSGradient(starting: NSColor.white.withAlphaComponent(start), ending: NSColor.white.withAlphaComponent(end))!
        .draw(in: path.bounds, angle: -55)
    NSGraphicsContext.restoreGraphicsState()
}

/// One pane of Liquid Glass.
func glass(_ path: NSBezierPath, tint: NSColor = .white, topAlpha: CGFloat = 0.55, bottomAlpha: CGFloat = 0.25,
           blur: CGFloat = 22, rimWidth: CGFloat = 5, shadow: Bool = true, shine: CGFloat = 0.5, lift: CGFloat = 1) {
    if shadow { castShadow(path, blur: 36 * lift, offset: 18 * lift, alpha: min(0.5, 0.34 + 0.06 * (lift - 1))) }

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    // the blurred scene behind the glass
    if let backdrop = blurredBackdrop(radius: blur) {
        cg.draw(backdrop, in: canvas)
    }
    // frosting and tint, lighter at the top
    NSGradient(starting: tint.withAlphaComponent(topAlpha), ending: tint.withAlphaComponent(bottomAlpha))!
        .draw(in: path.bounds, angle: -90)
    // darker, slightly saturated lower edge: the thickness of the glass
    NSGradient(colors: [NSColor.clear, hex(0x3B1A8C, 0.16)])!
        .draw(in: NSRect(x: path.bounds.minX, y: path.bounds.minY, width: path.bounds.width, height: path.bounds.height * 0.4),
              angle: -90)
    // specular highlight
    let b = path.bounds
    NSGradient(colors: [NSColor.white.withAlphaComponent(shine), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: b.minX + b.width * 0.25, y: b.maxY - b.height * 0.1), radius: 0,
              toCenter: NSPoint(x: b.minX + b.width * 0.25, y: b.maxY - b.height * 0.1), radius: max(b.width, b.height) * 0.62,
              options: [])
    NSGraphicsContext.restoreGraphicsState()

    rim(path, width: rimWidth)
}

func bar(_ rect: NSRect, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
}

// MARK: - The icon

func drawDeskIcon() {
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tile = NSBezierPath(roundedRect: body, xRadius: 190, yRadius: 190)

    // shadow of the whole icon
    NSGraphicsContext.saveGraphicsState()
    let outer = NSShadow()
    outer.shadowColor = NSColor.black.withAlphaComponent(0.38)
    outer.shadowOffset = NSSize(width: 0, height: -14)
    outer.shadowBlurRadius = 30
    outer.set()
    hex(0x7C5BF2).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    // the tile: a deep violet-to-magenta gradient with glowing corners
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [hex(0xA48BFF), hex(0x7A58F0), hex(0xB950D8)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: -50)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.34), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 330, y: 840), radius: 0, toCenter: NSPoint(x: 330, y: 840), radius: 560, options: [])
    NSGradient(colors: [hex(0xFF7AD9, 0.45), hex(0xFF7AD9, 0)])!
        .draw(fromCenter: NSPoint(x: 820, y: 170), radius: 0, toCenter: NSPoint(x: 820, y: 170), radius: 460, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // glass layers, back to front
    // legs
    glass(card(center: NSPoint(x: 322, y: 322), size: CGSize(width: 60, height: 140), radius: 22),
          topAlpha: 0.62, bottomAlpha: 0.3, blur: 14, rimWidth: 4.5, shine: 0.4)
    glass(card(center: NSPoint(x: 702, y: 322), size: CGSize(width: 60, height: 140), radius: 22),
          topAlpha: 0.62, bottomAlpha: 0.3, blur: 14, rimWidth: 4.5, shine: 0.4)

    // two notes behind: mint and pink
    glass(card(center: NSPoint(x: 412, y: 640), size: CGSize(width: 270, height: 270), angle: -10, radius: 34),
          tint: hex(0x6FE58A), topAlpha: 0.86, bottomAlpha: 0.62, blur: 12)
    glass(card(center: NSPoint(x: 618, y: 636), size: CGSize(width: 270, height: 270), angle: 10, radius: 34),
          tint: hex(0xFF8FC8), topAlpha: 0.88, bottomAlpha: 0.64, blur: 12)

    // the desk top
    glass(card(center: NSPoint(x: 512, y: 410), size: CGSize(width: 580, height: 62), radius: 31),
          topAlpha: 0.72, bottomAlpha: 0.4, blur: 16, rimWidth: 4.5, shine: 0.5)

    // the note on the desk
    let front = card(center: NSPoint(x: 512, y: 612), size: CGSize(width: 330, height: 330), angle: -2.5, radius: 42)
    glass(front, tint: hex(0xFFEE9A), topAlpha: 0.9, bottomAlpha: 0.7, blur: 20, rimWidth: 5.5, shine: 0.6)

    // what is written on it: a keyword, text, and a green result – like a DeskNotes note
    NSGraphicsContext.saveGraphicsState()
    cg.translateBy(x: 512, y: 612)
    cg.rotate(by: -2.5 * .pi / 180)
    let r = NSRect(x: -165, y: -165, width: 330, height: 330)
    bar(NSRect(x: r.minX + 46, y: r.maxY - 92, width: 118, height: 26), hex(0x4B35C9))
    bar(NSRect(x: r.minX + 46, y: r.maxY - 146, width: 238, height: 18), hex(0x4B35C9, 0.5))
    bar(NSRect(x: r.minX + 46, y: r.maxY - 192, width: 150, height: 18), hex(0x4B35C9, 0.5))
    bar(NSRect(x: r.minX + 212, y: r.maxY - 192, width: 72, height: 18), hex(0x2FBF5A))
    bar(NSRect(x: r.minX + 46, y: r.maxY - 238, width: 196, height: 18), hex(0x4B35C9, 0.5))
    NSGraphicsContext.restoreGraphicsState()

    // glass edge of the tile itself
    rim(tile, width: 7, start: 0.8, end: 0.10)
    NSColor.black.withAlphaComponent(0.16).setStroke()
    tile.lineWidth = 2
    tile.stroke()
}

func render(pixels: Int, _ draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    pixelScale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: pixelScale, y: pixelScale)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count > 1 else {
    print("usage: IconMaker <output-dir>")
    exit(1)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
// `IconMaker <dir>` draws the Apple II icon; `IconMaker <dir> desk` the violet desk one.
let style = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "apple"
let draw: () -> Void = style == "desk" ? drawDeskIcon : drawAppleIcon
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let files: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in files {
    try render(pixels: pixels, draw).write(to: iconset.appendingPathComponent(name + ".png"))
}
try render(pixels: 1024, draw).write(to: out.appendingPathComponent("preview.png"))
try render(pixels: 128, draw).write(to: out.appendingPathComponent("preview-small.png"))
print("wrote \(iconset.path)")
