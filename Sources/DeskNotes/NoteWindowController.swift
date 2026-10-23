import AppKit
import NotesCore

/// Reports the mouse entering / leaving the note, to fade the toolbar in and out.
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    /// The note's paper colour. The window paints it too; drawing it here makes snapshots complete.
    var fillColor: NSColor? { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) {
        fillColor?.setFill()
        dirtyRect.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(new)
        area = new
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// A round, softly tinted icon button for the toolbar pill.
final class CircleButton: NSButton {
    init(symbol: String, tip: String, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .imageOnly
        toolTip = tip
        setSymbol(symbol)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setSymbol(_ name: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    }

    private var fill = NSColor.clear

    func apply(theme: NoteTheme) {
        contentTintColor = theme.secondary
        fill = theme.text.withAlphaComponent(0.06)
        needsDisplay = true
    }

    /// The round background is drawn here (always a true circle, whatever size the stack gives us).
    override func draw(_ dirtyRect: NSRect) {
        let diameter = min(bounds.width, bounds.height)
        fill.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                                    width: diameter, height: diameter)).fill()
        super.draw(dirtyRect)
    }
}

/// One note on the desktop: a white rounded card with no visible title bar. A toolbar pill with
/// delete, date and options fades in at the bottom while the mouse is over the note.
final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let noteID: UUID
    var onNewNote: (() -> Void)?
    var onDelete: ((UUID) -> Void)?

    private let store: NoteStore
    private let storage = NSTextStorage()
    private let textView: NoteTextView
    private let styler: MarkdownStyler
    private var theme: NoteTheme
    private var isConfigured = false

    private let pill = NSVisualEffectView()
    private let dateLabel = NSTextField(labelWithString: "")
    private var trashButton: CircleButton!
    private var pinButton: CircleButton!
    private var buttons: [CircleButton] = []
    private var fontObserver: NSObjectProtocol?
    private var paper: HoverView!

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        return f
    }()

    init(note: Note, store: NoteStore) {
        self.noteID = note.id
        self.store = store
        self.theme = NoteTheme.named(note.themeID)
        self.styler = MarkdownStyler(theme: theme, fontSize: Settings.fontSize)

        // TextKit 1 stack, built by hand so we control the layout manager.
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        textView = NoteTextView(frame: NSRect(origin: .zero, size: note.frame.size), textContainer: container)

        let window = NSWindow(contentRect: note.frame,
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        super.init(window: window)
        configure(window: window, note: note)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let fontObserver { NotificationCenter.default.removeObserver(fontObserver) }
    }

    // MARK: Setup

    private func configure(window: NSWindow, note: Note) {
        window.delegate = self
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 260, height: 180)
        // Clean card: no traffic lights. ⌘W hides, the toolbar has a close button.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.setFrame(note.frame, display: false)

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        // Markdown needs literal characters: no smart quotes, no "--" → "–", no auto-corrections.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.delegate = self

        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: note.frame.size))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.documentView = textView
        scroll.autoresizingMask = [.width, .height]

        let container = HoverView(frame: NSRect(origin: .zero, size: note.frame.size))
        container.addSubview(scroll)
        container.onHover = { [weak self] inside in self?.setToolbarVisible(inside) }
        paper = container
        window.contentView = container
        buildToolbar(in: container)

        styler.textView = textView
        storage.delegate = styler
        textView.string = note.text
        textView.undoManager?.removeAllActions()

        setFloating(note.floats, persist: false)
        setAllSpaces(note.allSpaces, persist: false)
        applyTheme()
        updateDate()

        fontObserver = NotificationCenter.default.addObserver(forName: .fontSizeChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.styler.fontSize = Settings.fontSize
            self.restyle()
        }
        isConfigured = true
    }

    private func buildToolbar(in container: NSView) {
        trashButton = CircleButton(symbol: "trash", tip: "Delete note…", target: self, action: #selector(deleteNote))
        pinButton = CircleButton(symbol: "pin", tip: "Pin options", target: self, action: #selector(showPinMenu(_:)))
        let palette = CircleButton(symbol: "paintpalette", tip: "Colour", target: self, action: #selector(showThemeMenu(_:)))
        let plus = CircleButton(symbol: "plus", tip: "New note (⌘N)", target: self, action: #selector(newNoteClicked))
        let close = CircleButton(symbol: "xmark", tip: "Hide note (⌘W)", target: self, action: #selector(hideClicked))
        buttons = [trashButton, pinButton, palette, plus, close]

        dateLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        dateLabel.alignment = .center
        dateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [trashButton, dateLabel, pinButton, palette, plus, close])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false

        pill.material = .popover
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 24
        pill.layer?.masksToBounds = true
        pill.layer?.borderWidth = 0.5
        pill.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(stack)
        container.addSubview(pill)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            stack.topAnchor.constraint(equalTo: pill.topAnchor),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
            pill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            pill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            pill.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            pill.heightAnchor.constraint(equalToConstant: 48),
        ])
        pill.alphaValue = 0
        pill.isHidden = true
    }

    private func setToolbarVisible(_ visible: Bool, animated: Bool = true) {
        if visible {
            pill.isHidden = false
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    pill.animator().alphaValue = 1
                }
            } else {
                pill.alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                pill.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // Hidden views don't swallow clicks meant for the text underneath.
                if self?.pill.alphaValue == 0 { self?.pill.isHidden = true }
            })
        }
    }

    // MARK: Appearance

    private func applyTheme() {
        window?.backgroundColor = theme.background
        paper.fillColor = theme.background
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        pill.appearance = window?.appearance
        pill.layer?.borderColor = theme.text.withAlphaComponent(0.10).cgColor
        dateLabel.textColor = theme.secondary
        textView.theme = theme
        styler.theme = theme
        buttons.forEach { $0.apply(theme: theme) }
        restyle()
    }

    private func restyle() {
        textView.baseFont = styler.baseFont
        storage.beginEditing()
        styler.style(storage)
        storage.endEditing()
        textView.updateInsets()
        textView.needsDisplay = true
    }

    private func updatePinIcon() {
        let note = store.notes[noteID]
        let active = (note?.floats ?? false) || (note?.allSpaces ?? false)
        pinButton?.setSymbol(active ? "pin.fill" : "pin")
    }

    private func updateDate() {
        let date = store.notes[noteID]?.modified ?? Date()
        dateLabel.stringValue = Self.dateFormatter.string(from: date)
    }

    // MARK: Show / hide

    func show(focus: Bool = true) {
        guard let window else { return }
        store.update(noteID, touch: false) { $0.isVisible = true }
        window.orderFrontRegardless()
        if focus {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    func hide() {
        window?.orderOut(nil)
        store.update(noteID, touch: false) { $0.isVisible = false }
    }

    var isShown: Bool { window?.isVisible ?? false }

    /// Hides without recording it, so "Hide All Notes" doesn't forget which notes were open.
    func hideTemporarily() {
        window?.orderOut(nil)
    }

    // MARK: Actions

    @objc private func newNoteClicked() { onNewNote?() }
    @objc private func hideClicked() { hide() }

    @objc private func showThemeMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for candidate in NoteTheme.all {
            let item = NSMenuItem(title: candidate.name, action: #selector(themeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.id
            item.image = candidate.swatch
            item.state = candidate.id == theme.id ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func themeChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        theme = NoteTheme.named(id)
        store.update(noteID, touch: false) { $0.themeID = id }
        applyTheme()
    }

    @objc private func showPinMenu(_ sender: NSButton) {
        let note = store.notes[noteID]
        let menu = NSMenu()
        let float = NSMenuItem(title: "Float Above Other Windows", action: #selector(toggleFloating), keyEquivalent: "")
        float.target = self
        float.state = (note?.floats ?? false) ? .on : .off
        let spaces = NSMenuItem(title: "Show on All Desktops", action: #selector(toggleAllSpaces), keyEquivalent: "")
        spaces.target = self
        spaces.state = (note?.allSpaces ?? false) ? .on : .off
        menu.addItem(float)
        menu.addItem(spaces)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func toggleFloating() { setFloating(!(store.notes[noteID]?.floats ?? false)) }
    @objc private func toggleAllSpaces() { setAllSpaces(!(store.notes[noteID]?.allSpaces ?? false)) }

    private func setFloating(_ on: Bool, persist: Bool = true) {
        window?.level = on ? .floating : .normal
        if persist { store.update(noteID, touch: false) { $0.floats = on } }
        updatePinIcon()
    }

    private func setAllSpaces(_ on: Bool, persist: Bool = true) {
        // A note follows you to the desktop you are on when you bring it up from the menu bar.
        window?.collectionBehavior = on ? [.canJoinAllSpaces] : [.moveToActiveSpace]
        if persist { store.update(noteID, touch: false) { $0.allSpaces = on } }
        updatePinIcon()
    }

    @objc func deleteNote() {
        let hasText = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText {
            let alert = NSAlert()
            alert.messageText = "Delete this note?"
            alert.informativeText = "The note file is moved to the Trash, so you can still recover it from there."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        onDelete?(noteID)
    }

    // MARK: NSWindowDelegate

    /// ⌘W only hides the note; it stays in the menu bar list.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) {
        saveFrame()
        // During a drag, restyle once at the end instead of on every step.
        if window?.inLiveResize != true { restyleForNewWidth() }
    }

    func windowDidEndLiveResize(_ notification: Notification) { restyleForNewWidth() }

    /// Line wrapping changed: results that don't fit move to their own line (see MarkdownStyler).
    private func restyleForNewWidth() {
        if isConfigured, !textView.analysis.results.isEmpty { restyle() }
    }

    private func saveFrame() {
        guard isConfigured, let frame = window?.frame else { return }
        store.update(noteID, touch: false) { $0.frame = frame }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        let text = textView.string
        store.update(noteID) { $0.text = text }
        updateDate()
    }

    // MARK: Snapshot (`DeskNotes --snapshot <dir>`)

    /// Renders the note as it looks on screen, for checking the design without a screenshot.
    func snapshotPNG(showToolbar: Bool) -> Data? {
        guard let window, let view = window.contentView else { return nil }
        window.alphaValue = 0
        window.orderFrontRegardless()
        if showToolbar { setToolbarVisible(true, animated: false) }
        textView.updateInsets()
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        view.displayIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
