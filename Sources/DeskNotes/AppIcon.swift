import AppKit

enum AppIcon {
    /// The menu bar glyph: a rounded screen, like a computer display, with a note in the middle.
    /// A template image, so macOS tints it for light / dark menu bars.
    static func statusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // screen: a rounded rectangle outline
            let screenLine: CGFloat = 1.5
            let screen = NSBezierPath(roundedRect: NSRect(x: 1, y: 2.2, width: 18, height: 13.6).insetBy(dx: screenLine / 2, dy: screenLine / 2),
                                      xRadius: 3.6, yRadius: 3.6)
            screen.lineWidth = screenLine
            screen.stroke()

            // note in the middle: a small rounded outline with three lines of text
            let note = NSBezierPath(roundedRect: NSRect(x: 6.4, y: 4.9, width: 7.2, height: 8.2), xRadius: 1.6, yRadius: 1.6)
            note.lineWidth = 1.2
            note.stroke()
            for (y, x2) in [(10.8, 11.6), (8.9, 11.6), (7.0, 10.0)] as [(CGFloat, CGFloat)] {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 8.4, y: y))
                line.line(to: NSPoint(x: x2, y: y))
                line.lineWidth = 1.0
                line.lineCapStyle = .round
                line.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
