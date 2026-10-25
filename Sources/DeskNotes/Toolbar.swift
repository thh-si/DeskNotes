import AppKit
import NotesCore

/// Liquid Glass (macOS 26 and later), with a frosted-blur look on older systems.
/// Standard controls (buttons, sliders, menus, popovers) pick up the new look from macOS by
/// themselves; this is for the surfaces DeskNotes draws itself.
@MainActor
enum Glass {
    /// `DESKNOTES_NO_GLASS=1` forces the older look, to check it on a new system.
    static var isAvailable: Bool {
        guard ProcessInfo.processInfo.environment["DESKNOTES_NO_GLASS"] == nil else { return false }
        if #available(macOS 26, *) { return true }
        return false
    }

    /// A capsule of glass around `content`, of a fixed size.
    static func capsule(around content: NSView, width: CGFloat, height: CGFloat) -> NSView {
        let capsule: NSView
        if isAvailable, #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = height / 2
            glass.contentView = content
            capsule = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .withinWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = height / 2
            blur.layer?.masksToBounds = true
            blur.layer?.borderWidth = 0.5
            blur.addSubview(content)
            capsule = blur
        }
        capsule.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        pin(content, to: capsule)
        NSLayoutConstraint.activate([
            capsule.widthAnchor.constraint(equalToConstant: width),
            capsule.heightAnchor.constraint(equalToConstant: height),
        ])
        return capsule
    }

    /// Glass capsules in one container are drawn and animated as a group.
    static func group(_ content: NSView) -> NSView {
        guard isAvailable, #available(macOS 26, *) else { return content }
        let container = NSGlassEffectContainerView()
        container.contentView = content
        container.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        pin(content, to: container)
        return container
    }

    /// The thin outline of the older look; real glass draws its own edge.
    static func setBorder(of capsule: NSView, to color: NSColor) {
        (capsule as? NSVisualEffectView)?.layer?.borderColor = color.cgColor
    }

    private static func pin(_ view: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            view.topAnchor.constraint(equalTo: parent.topAnchor),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}

/// A round icon button for the toolbar. Plain until the mouse is over it or it is pressed, then a
/// soft round highlight appears, like the selected button in Finder's toolbar.
final class CircleButton: NSButton {
    static let diameter: CGFloat = 32

    private var highlightColor = NSColor.clear
    private var isHovering = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    init(symbol: String, tip: String, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .imageOnly
        toolTip = tip
        setSymbol(symbol)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.diameter).isActive = true
        heightAnchor.constraint(equalToConstant: Self.diameter).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setSymbol(_ name: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    }

    func apply(theme: NoteTheme) {
        contentTintColor = theme.secondary
        highlightColor = theme.text.withAlphaComponent(0.10)
        needsDisplay = true
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(new)
        area = new
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// The highlight is drawn here: always a true circle, whatever size the stack gives us.
    override func draw(_ dirtyRect: NSRect) {
        if isHovering || isHighlighted {
            let diameter = min(bounds.width, bounds.height)
            highlightColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                                        width: diameter, height: diameter)).fill()
        }
        super.draw(dirtyRect)
    }
}

/// "Opacity ——●—— 85 %" as a row of the colour menu. Moving the slider changes the note live.
final class OpacitySliderView: NSView {
    var onChange: (@MainActor (Double) -> Void)?

    private let slider = NSSlider(value: 1, minValue: Note.opacityRange.lowerBound, maxValue: 1, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "")

    init(opacity: Double) {
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 56))

        let title = NSTextField(labelWithString: "Opacity")
        title.font = .systemFont(ofSize: 13)
        title.textColor = .secondaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor

        slider.target = self
        slider.action = #selector(moved)
        slider.isContinuous = true
        slider.doubleValue = Note.clampOpacity(opacity)

        let header = NSStackView(views: [title, valueLabel])
        header.orientation = .horizontal
        header.distribution = .fill
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [header, slider])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            slider.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        showValue()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func moved() {
        if slider.doubleValue > 0.97 { slider.doubleValue = 1 }  // a little pull towards "solid"
        showValue()
        onChange?(slider.doubleValue)
    }

    private func showValue() {
        let value = slider.doubleValue
        valueLabel.stringValue = value >= 0.995 ? "Solid" : "\(Int((value * 100).rounded())) %"
    }
}
