import AppKit

enum AppIcon {
    /// The menu bar glyph, after the rough sketch: a note with three lines standing on a small desk.
    /// A template image, so macOS tints it for light / dark menu bars.
    static func statusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // desk: top plate and two legs
            NSBezierPath(roundedRect: NSRect(x: 1, y: 5.4, width: 18, height: 2.4), xRadius: 1.2, yRadius: 1.2).fill()
            NSBezierPath(rect: NSRect(x: 3, y: 0.8, width: 1.7, height: 4.8)).fill()
            NSBezierPath(rect: NSRect(x: 15.3, y: 0.8, width: 1.7, height: 4.8)).fill()

            // note: rounded square outline with three lines of text
            let note = NSBezierPath(roundedRect: NSRect(x: 4.6, y: 8.5, width: 10.8, height: 8.5), xRadius: 2, yRadius: 2)
            note.lineWidth = 1.4
            note.stroke()
            for (y, x2) in [(14.6, 12.6), (12.6, 12.6), (10.6, 10.4)] as [(CGFloat, CGFloat)] {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 7, y: y))
                line.line(to: NSPoint(x: x2, y: y))
                line.lineWidth = 1.1
                line.lineCapStyle = .round
                line.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
