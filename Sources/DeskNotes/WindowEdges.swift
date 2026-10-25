import AppKit

/// A note moves by its top edge: the open hand shows there and a drag moves the window. The sides and
/// the bottom resize it the standard macOS way, with the system's own resize border.

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

/// The note's window. The system lets a titled window be resized from its top edge too; here the
/// top few points move the window instead (the sides and the bottom keep the standard behaviour).
final class NoteWindow: NSWindow {
    private static let moveBand: CGFloat = 8

    private func isInMoveBand(_ event: NSEvent) -> Bool {
        event.window === self && event.locationInWindow.y >= frame.height - Self.moveBand
    }

    override func sendEvent(_ event: NSEvent) {
        // A click anywhere on a note brings it forward. The system doesn't do it by itself when the
        // click is taken by something that acts on the first click (toolbar buttons, the move strip,
        // the top band below), and DeskNotes, as a menu bar app, is rarely the active app.
        if event.type == .leftMouseDown || event.type == .rightMouseDown, !NSApp.isActive || !isKeyWindow {
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            makeKeyAndOrderFront(nil)
        }
        switch event.type {
        case .leftMouseDown where isInMoveBand(event):
            performDrag(with: event)
        case .mouseMoved, .cursorUpdate, .mouseEntered:
            super.sendEvent(event)
            if isInMoveBand(event) { NSCursor.openHand.set() }
        default:
            super.sendEvent(event)
        }
    }
}
