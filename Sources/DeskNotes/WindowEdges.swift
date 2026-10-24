import AppKit

/// The top edge of a note moves it (open hand); the left, right and bottom edges resize it.
/// The window has no system resize border, because that one also resizes from the top.

/// A strip along the top of the note: drag to move the window.
final class MoveStripView: NSView {
    static let height: CGFloat = 22

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.push()
        window?.performDrag(with: event)
        NSCursor.pop()
    }
}

/// An invisible handle on one edge or bottom corner of the note.
final class ResizeEdgeView: NSView {
    enum Edge { case left, right, bottom, bottomLeft, bottomRight }

    static let thickness: CGFloat = 6
    static let corner: CGFloat = 16

    let edge: Edge
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var cursor: NSCursor {
        switch edge {
        case .left, .right: return .resizeLeftRight
        case .bottom: return .resizeUpDown
        case .bottomLeft, .bottomRight:
            // The diagonal arrows exist in AppKit but are not public; fall back to a crosshair.
            let name = edge == .bottomLeft ? "_windowResizeNorthEastSouthWestCursor" : "_windowResizeNorthWestSouthEastCursor"
            let selector = NSSelectorFromString(name)
            if NSCursor.responds(to: selector), let cursor = NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor {
                return cursor
            }
            return .crosshair
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = NSEvent.mouseLocation
        let original = window.frame
        let minimum = window.minSize
        let movesLeft = edge == .left || edge == .bottomLeft
        let movesRight = edge == .right || edge == .bottomRight
        let movesBottom = edge == .bottom || edge == .bottomLeft || edge == .bottomRight

        onBegin?()
        defer { onEnd?() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type != .leftMouseUp {
            let dx = NSEvent.mouseLocation.x - start.x
            let dy = NSEvent.mouseLocation.y - start.y
            var frame = original
            if movesLeft {
                frame.size.width = max(minimum.width, original.width - dx)
                frame.origin.x = original.maxX - frame.size.width
            }
            if movesRight { frame.size.width = max(minimum.width, original.width + dx) }
            if movesBottom {
                frame.size.height = max(minimum.height, original.height - dy)
                frame.origin.y = original.maxY - frame.size.height
            }
            window.setFrame(frame, display: true)
        }
    }
}
