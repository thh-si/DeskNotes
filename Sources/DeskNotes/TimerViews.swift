import AppKit
import NotesCore

/// The help bubble under a `timer` line: what Return will do, and the other commands.
final class TimerHintView: NSVisualEffectView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private static let padding: CGFloat = 12

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks go through to the text underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Fills the bubble and returns its size for a given maximum width.
    func setText(first: String, sheet: [String], maxWidth: CGFloat) -> NSSize {
        label.stringValue = ([first] + (sheet.isEmpty ? [] : [""] + sheet)).joined(separator: "\n")
        let textWidth = max(120, maxWidth - 2 * Self.padding)
        label.preferredMaxLayoutWidth = textWidth
        let size = label.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        label.frame = NSRect(x: Self.padding, y: Self.padding, width: textWidth, height: size.height)
        return NSSize(width: textWidth + 2 * Self.padding, height: size.height + 2 * Self.padding)
    }
}

/// The running timer, in the top-right corner of the note that started it. A click pauses or
/// resumes it, a double-click stops it.
final class TimerBadgeView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private var display: TimerDisplay?
    private var theme = NoteTheme.fallback

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Click to pause, double-click to stop"
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(display: TimerDisplay?, theme: NoteTheme) {
        self.display = display
        self.theme = theme
        isHidden = display == nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Self.font, .foregroundColor: display?.isPaused == true ? theme.secondary : theme.timerColor]
    }

    override var intrinsicContentSize: NSSize {
        guard let display else { return .zero }
        let text = (display.menuBarText as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(text.width) + 34, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let display else { return }
        theme.text.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        // A dot while it runs, like the one in the corner of a note with a timer.
        let dot = NSRect(x: 10, y: bounds.midY - 3, width: 6, height: 6)
        (display.isPaused ? theme.secondary : theme.timerColor).setFill()
        NSBezierPath(ovalIn: dot).fill()

        let text = display.menuBarText as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: 22, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // The second click of a double-click first paused or resumed; stopping ends it either way.
        if event.clickCount >= 2 { onDoubleClick?() } else { onClick?() }
    }
}
