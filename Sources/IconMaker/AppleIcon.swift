import AppKit

// The "Apple II" icon: a beige monitor whose recessed glass screen shows the classic rainbow bands
// as its desktop wallpaper, speaker slots and a power light below it, and a pile of three
// Liquid Glass notes floating above the screen.
// Helpers (glass, rim, castShadow …) live in main.swift.

/// A rounded rectangle with a bulge: |x/rx|^n + |y/ry|^n = 1. n = 2 is an ellipse, large n a box.
func superellipse(center: NSPoint, rx: CGFloat, ry: CGFloat, power n: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 240
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = NSPoint(x: center.x + rx * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                            y: center.y + ry * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        if i == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

/// A handwritten squiggle starting at `origin`, `width` wide.
func squiggle(from origin: NSPoint, width: CGFloat, amplitude: CGFloat, waves: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 90
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let swing = amplitude * (0.75 + 0.25 * sin(t * .pi * 2.3))   // a little uneven, like handwriting
        let point = NSPoint(x: origin.x + t * width, y: origin.y + sin(t * waves * 2 * .pi) * swing)
        if i == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.lineWidth = 11
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

func drawAppleIcon() {
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tile = NSBezierPath(roundedRect: body, xRadius: 190, yRadius: 190)
    let middle = NSPoint(x: 512, y: 562)

    // shadow of the whole icon
    NSGraphicsContext.saveGraphicsState()
    let outer = NSShadow()
    outer.shadowColor = NSColor.black.withAlphaComponent(0.38)
    outer.shadowOffset = NSSize(width: 0, height: -14)
    outer.shadowBlurRadius = 30
    outer.set()
    hex(0xD9CBA8).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    // the case: warm beige plastic
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [hex(0xFBF6E8), hex(0xE9DEC2), hex(0xCFC09C)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: -90)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.6), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 280, y: 900), radius: 0, toCenter: NSPoint(x: 280, y: 900), radius: 520, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // MARK: below the screen

    // speaker slots: dark cuts with a bright lower lip
    for i in 0..<5 {
        let slot = NSRect(x: 266 + CGFloat(i) * 30, y: 142, width: 16, height: 72)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: slot.offsetBy(dx: 0, dy: -3.5), xRadius: 8, yRadius: 8).fill()
        NSGradient(starting: hex(0x4E3F22, 0.85), ending: hex(0x7A6840, 0.75))!
            .draw(in: NSBezierPath(roundedRect: slot, xRadius: 8, yRadius: 8), angle: -90)
    }

    // power light: a glowing amber dome
    let lightCenter = NSPoint(x: 718, y: 178)
    NSGradient(colors: [hex(0xFF9A1F, 0.7), hex(0xFF9A1F, 0)])!
        .draw(fromCenter: lightCenter, radius: 0, toCenter: lightCenter, radius: 74, options: [])
    let socket = NSBezierPath(ovalIn: NSRect(x: lightCenter.x - 25, y: lightCenter.y - 25, width: 50, height: 50))
    NSGradient(starting: hex(0x6E5C38, 0.8), ending: hex(0xFFFFFF, 0.9))!.draw(in: socket, angle: -90)
    let dome = NSBezierPath(ovalIn: NSRect(x: lightCenter.x - 19, y: lightCenter.y - 19, width: 38, height: 38))
    NSGradient(starting: hex(0xFFE08A), ending: hex(0xFF7A00))!.draw(in: dome, angle: -90)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.85), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: lightCenter.x - 6, y: lightCenter.y + 8), radius: 0,
              toCenter: NSPoint(x: lightCenter.x - 6, y: lightCenter.y + 8), radius: 15, options: [])

    // MARK: the screen

    // the recess in the case
    let bezel = superellipse(center: middle, rx: 340, ry: 292, power: 7)
    NSGradient(starting: hex(0xB5A685), ending: hex(0xF0E8D2))!.draw(in: bezel, angle: -90)
    NSColor(srgbRed: 0.35, green: 0.28, blue: 0.14, alpha: 0.28).setStroke()
    bezel.lineWidth = 2
    bezel.stroke()

    // the screen, sunk into the recess
    let screen = superellipse(center: middle, rx: 300, ry: 252, power: 8)
    castShadow(screen, blur: 26, offset: -10, alpha: 0.5, color: 0x3A2A10)

    NSGraphicsContext.saveGraphicsState()
    screen.addClip()
    hex(0x050506).setFill()
    screen.fill()

    // the wallpaper: the classic six-colour rainbow, flat and crisp. The first and last band run on
    // outwards, so the glass is always covered.
    cg.saveGState()
    cg.translateBy(x: middle.x, y: middle.y)
    cg.rotate(by: -69 * .pi / 180)   // bands run up to the right at 21°, stacked from top to bottom
    let stripes = [0x62C23A, 0xFFB92E, 0xFF7A1F, 0xF03A3E, 0x9B2F9E, 0x2B8FE0]
    let width: CGFloat = 118
    let first = -CGFloat(stripes.count) * width / 2
    for (i, value) in stripes.enumerated() {
        var left = first + CGFloat(i) * width
        var right = left + width + 0.5
        if i == 0 { left = -2000 }
        if i == stripes.count - 1 { right = 2000 }
        hex(value).setFill()
        NSRect(x: left, y: -1200, width: right - left, height: 2400).fill()
    }
    cg.restoreGState()

    // curved glass: slightly darker towards the corners, a soft reflection top left
    NSGradient(colors: [NSColor.clear, NSColor.black.withAlphaComponent(0.2)])!
        .draw(fromCenter: middle, radius: 190, toCenter: middle, radius: 420, options: [.drawsAfterEndingLocation])
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.2), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 390, y: 740), radius: 0, toCenter: NSPoint(x: 390, y: 740), radius: 300, options: [])
    NSGraphicsContext.restoreGraphicsState()
    rim(screen, width: 5, start: 0.55, end: 0.05)

    // MARK: three notes floating above the glass (higher notes cast longer, softer shadows)

    glass(card(center: NSPoint(x: 476, y: 598), size: CGSize(width: 280, height: 280), angle: 10, radius: 37),
          tint: .white, topAlpha: 0.74, bottomAlpha: 0.52, blur: 14, rimWidth: 4.5, lift: 1.6)
    glass(card(center: NSPoint(x: 548, y: 578), size: CGSize(width: 280, height: 280), angle: -8, radius: 37),
          tint: .white, topAlpha: 0.82, bottomAlpha: 0.6, blur: 14, rimWidth: 4.5, lift: 2.1)
    let front = card(center: NSPoint(x: 512, y: 548), size: CGSize(width: 280, height: 280), angle: 2, radius: 37)
    glass(front, tint: .white, topAlpha: 0.94, bottomAlpha: 0.8, blur: 18, rimWidth: 5, shine: 0.6, lift: 2.7)

    // what is written on the front note: one squiggle and a few straight lines
    NSGraphicsContext.saveGraphicsState()
    cg.translateBy(x: 512, y: 548)
    cg.rotate(by: 2 * .pi / 180)
    let r = NSRect(x: -140, y: -140, width: 280, height: 280)
    hex(0x1F4468).setStroke()
    squiggle(from: NSPoint(x: r.minX + 40, y: r.maxY - 74), width: 150, amplitude: 14, waves: 4.5).stroke()
    bar(NSRect(x: r.minX + 40, y: r.maxY - 138, width: 200, height: 16), hex(0x3F3A36, 0.36))
    bar(NSRect(x: r.minX + 40, y: r.maxY - 176, width: 160, height: 16), hex(0x3F3A36, 0.36))
    bar(NSRect(x: r.minX + 40, y: r.maxY - 214, width: 184, height: 16), hex(0x3F3A36, 0.36))
    NSGraphicsContext.restoreGraphicsState()

    // glass edge of the case
    rim(tile, width: 7, start: 0.9, end: 0.15)
    NSColor.black.withAlphaComponent(0.14).setStroke()
    tile.lineWidth = 2
    tile.stroke()
}
