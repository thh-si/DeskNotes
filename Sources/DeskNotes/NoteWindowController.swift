import AppKit
import NotesCore
import SwiftUI

/// Reports the mouse entering / leaving the note, to fade the toolbar in and out.
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

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

/// The note's paper colour, with the note's opacity as its alpha. Sits above the blur layer, below
/// the text. Drawn (not a layer colour) so that snapshots include it.
final class TintView: NSView {
    var fillColor = NSColor.white { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        dirtyRect.fill(using: .copy)
    }
}

/// One note on the desktop: a white rounded card with no visible title bar. A toolbar pill with
/// delete, date and options fades in at the bottom while the mouse is over the note.
final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSPopoverDelegate {
    let noteID: UUID
    var onNewNote: (() -> Void)?
    var onSearch: (() -> Void)?
    var settingsMenu: (() -> NSMenu)?
    var onDelete: ((UUID) -> Void)?
    var onSetReminder: ((UUID, Date) -> Void)?
    var onClearReminder: ((UUID) -> Void)?
    var onSetSlot: ((UUID, Int?) -> Void)?
    var onTimerCommand: ((UUID, TimerCommand) -> Void)?
    var onTimerToggle: (() -> Void)?
    var onTimerStop: (() -> Void)?

    private let store: NoteStore
    private let storage = NSTextStorage()
    private let textView: NoteTextView
    private let styler: MarkdownStyler
    private var theme: NoteTheme
    private var isConfigured = false

    /// The toolbar: two glass capsules with the date between them.
    private var pill: NSView!
    /// The top toolbar: settings and search on the left, new note and the front / back choice on the right.
    private var topPill: NSView!
    private var layerButton: CircleButton!
    private var capsules: [NSView] = []
    private let dateLabel = NSTextField(labelWithString: "")
    /// The capsule behind the date; its width follows the text.
    private var dateWidth: NSLayoutConstraint?
    /// The popover that is open right now (reminder), if any. The toolbar stays while it is open.
    private var popover: NSPopover?
    private var isMouseInside = false
    private var trashButton: CircleButton!
    private var pinButton: CircleButton!
    private var buttons: [CircleButton] = []
    /// Frosted blur of what is behind the window; only visible when the note is translucent.
    private let backdrop = NSVisualEffectView()
    private let tint = TintView()
    /// The running timer, when it was started from this note.
    private let timerBadge = TimerBadgeView(frame: .zero)
    private var timerDisplay: TimerDisplay?

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
    private static let shortDate = formatter("dMMM")
    private static let longDate = formatter("dMMMyyyy")

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

        let window = NoteWindow(contentRect: note.frame,
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        super.init(window: window)
        configure(window: window, note: note)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Setup

    private func configure(window: NSWindow, note: Note) {
        window.delegate = self
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true  // NoteWindow shows the move cursor along the top edge
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 300, height: 180)
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
        // Writing Tools (macOS 15+) takes over a large selection and locks the editor: after ⌘A nothing
        // reacts and the text is covered by its overlay. The notes draw their own results, so keep it off.
        if #available(macOS 15.0, *) { textView.writingToolsBehavior = .none }
        textView.importsGraphics = false
        // Markdown needs literal characters: never smart quotes or "--" → "–".
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        applyTextPrefs()
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

        // Translucency: the window itself is see-through; blur and paper colour are views inside it.
        window.isOpaque = false
        window.backgroundColor = .clear
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active  // keep the blur when the note isn't the active window
        for layer in [backdrop, tint] as [NSView] {
            layer.frame = NSRect(origin: .zero, size: note.frame.size)
            layer.autoresizingMask = [.width, .height]
        }

        let container = HoverView(frame: NSRect(origin: .zero, size: note.frame.size))
        container.addSubview(backdrop)
        container.addSubview(tint)
        container.addSubview(scroll)
        container.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        window.contentView = container
        addEdges(to: container)
        buildToolbar(in: container)
        buildTimerBadge(in: container)
        textView.onTimerCommand = { [weak self] command in
            guard let self else { return }
            self.onTimerCommand?(self.noteID, command)
        }

        styler.textView = textView
        storage.delegate = styler
        textView.string = note.text
        textView.undoManager?.removeAllActions()

        setLayer(floats: note.floats, behind: note.behind, persist: false)
        setAllSpaces(note.allSpaces, persist: false)
        applyTheme()
        updateDate()

        // Selector-based, so AppKit removes the observer by itself when the controller goes away.
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeChanged), name: .fontSizeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyTextPrefs), name: .textPrefsChanged, object: nil)
        isConfigured = true
    }

    /// Spell checking and the system's text replacements, as set in the Edit menu.
    @objc private func applyTextPrefs() {
        textView.isContinuousSpellCheckingEnabled = Settings.spellChecking
        textView.isAutomaticTextReplacementEnabled = Settings.textReplacement
        textView.isAutomaticSpellingCorrectionEnabled = Settings.autoCorrect
    }

    @objc private func fontSizeChanged() {
        styler.fontSize = Settings.fontSize
        restyle()
    }

    private func buildToolbar(in container: NSView) {
        trashButton = CircleButton(symbol: "trash", tip: "Delete note…", target: self, action: #selector(deleteNote))
        pinButton = CircleButton(symbol: "pin", tip: "Pin and reminder", target: self, action: #selector(showPinMenu(_:)))
        let palette = CircleButton(symbol: "paintpalette", tip: "Colour and opacity", target: self, action: #selector(showThemeMenu(_:)))
        let close = CircleButton(symbol: "xmark", tip: "Hide note (⌘W)", target: self, action: #selector(hideClicked))
        let settings = CircleButton(symbol: "slider.horizontal.3", tip: "Settings", target: self, action: #selector(showSettingsMenu(_:)))
        let search = CircleButton(symbol: "magnifyingglass", tip: "Search Notes (⌘F)", target: self, action: #selector(searchClicked))
        let plus = CircleButton(symbol: "square.and.pencil", tip: "New note (⌘N)", target: self, action: #selector(newNoteClicked))
        layerButton = CircleButton(symbol: "square.3.layers.3d", tip: "In front of or behind other windows", target: self,
                                   action: #selector(showLayerMenu(_:)))
        buttons = [trashButton, pinButton, palette, close, settings, search, plus, layerButton]

        // Two capsules of glass, like the grouped buttons of Finder's toolbar, with the date between.
        let height: CGFloat = 40
        func capsule(_ views: [CircleButton]) -> NSView {
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 2
            row.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            let width = CGFloat(views.count) * CircleButton.diameter + CGFloat(views.count - 1) * 2 + 8
            return Glass.capsule(around: row, width: width, height: height)
        }
        capsules = [capsule([trashButton, pinButton, palette]), capsule([close])]

        dateLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        dateLabel.alignment = .center
        dateLabel.lineBreakMode = .byTruncatingTail
        dateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let dateRow = NSStackView(views: [dateLabel])
        dateRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let dateCapsule = Glass.capsule(around: dateRow, width: 80, height: height)
        dateWidth = dateCapsule.constraints.first { $0.firstAttribute == .width }
        dateWidth?.priority = .defaultHigh  // may shrink in a narrow note; the text then truncates
        capsules.append(dateCapsule)

        // Equal flexible gaps on both sides keep the date centred.
        let gapLeft = NSView(), gapRight = NSView()
        for gap in [gapLeft, gapRight] {
            gap.translatesAutoresizingMaskIntoConstraints = false
            gap.setContentHuggingPriority(.init(1), for: .horizontal)
            gap.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        }
        let bar = NSStackView(views: [capsules[0], gapLeft, dateCapsule, gapRight, capsules[1]])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.distribution = .fill
        bar.spacing = 6
        gapLeft.widthAnchor.constraint(equalTo: gapRight.widthAnchor).isActive = true

        pill = Glass.group(bar)
        pill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            pill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            pill.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            pill.heightAnchor.constraint(equalToConstant: height),
        ])
        pill.alphaValue = 0
        pill.isHidden = true

        // The top toolbar: two capsules, left and right.
        let topLeft = capsule([settings, search]), topRight = capsule([plus, layerButton])
        capsules += [topLeft, topRight]
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let topBar = NSStackView(views: [topLeft, spacer, topRight])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.distribution = .fill
        topPill = Glass.group(topBar)
        topPill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topPill)
        NSLayoutConstraint.activate([
            topPill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            topPill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            topPill.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            topPill.heightAnchor.constraint(equalToConstant: height),
        ])
        topPill.alphaValue = 0
        topPill.isHidden = true
    }

    /// A strip along the top moves the note (the sides and bottom resize it, as in any macOS window).
    private func addEdges(to container: NSView) {
        let size = container.bounds.size
        let strip = MoveStripView(frame: NSRect(x: 0, y: size.height - MoveStripView.height, width: size.width, height: MoveStripView.height))
        strip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(strip)
    }

    private func buildTimerBadge(in container: NSView) {
        timerBadge.translatesAutoresizingMaskIntoConstraints = false
        timerBadge.onClick = { [weak self] in self?.onTimerToggle?() }
        timerBadge.onDoubleClick = { [weak self] in self?.onTimerStop?() }
        container.addSubview(timerBadge)
        NSLayoutConstraint.activate([
            timerBadge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            timerBadge.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
        ])
    }

    /// Shows the timer in the corner of this note, or removes it (nil).
    func setTimerDisplay(_ display: TimerDisplay?) {
        timerDisplay = display
        timerBadge.update(display: display, theme: theme)
    }

    private func hoverChanged(_ inside: Bool) {
        isMouseInside = inside
        if !inside, popover != nil { return }  // the toolbar stays while its popover is open
        setToolbarVisible(inside)
    }

    private func setToolbarVisible(_ visible: Bool, animated: Bool = true) {
        let pills: [NSView] = [pill, topPill]
        if visible {
            pills.forEach { $0.isHidden = false }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    pills.forEach { $0.animator().alphaValue = 1 }
                }
            } else {
                pills.forEach { $0.alphaValue = 1 }
            }
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                pills.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                // Hidden views don't swallow clicks meant for the text underneath.
                MainActor.assumeIsolated {  // AppKit calls this on the main thread
                    guard let self else { return }
                    for view in [self.pill, self.topPill] where view?.alphaValue == 0 { view?.isHidden = true }
                }
            })
        }
    }

    // MARK: Appearance

    private func applyTheme() {
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        backdrop.appearance = window?.appearance
        applyOpacity()
        pill.appearance = window?.appearance
        topPill.appearance = window?.appearance
        capsules.forEach { Glass.setBorder(of: $0, to: theme.text.withAlphaComponent(0.10)) }
        dateLabel.textColor = theme.secondary
        textView.theme = theme
        styler.theme = theme
        buttons.forEach { $0.apply(theme: theme) }
        timerBadge.update(display: timerDisplay, theme: theme)
        restyle()
    }

    /// Paper colour at the note's opacity; below 100 % the blurred desktop shows through.
    private func applyOpacity() {
        let opacity = store.notes[noteID]?.opacity ?? 1
        tint.fillColor = theme.background.withAlphaComponent(opacity)
        backdrop.isHidden = opacity >= 0.995
        window?.invalidateShadow()
    }

    private func restyle() {
        textView.baseFont = styler.baseFont
        storage.beginEditing()
        styler.style(storage)
        storage.endEditing()
        textView.updateInsets()
        textView.emptyTypingAttributes = styler.baseTypingAttributes
        if textView.string.isEmpty { textView.typingAttributes = styler.baseTypingAttributes }
        textView.needsDisplay = true
    }

    private func updatePinIcon() {
        let note = store.notes[noteID]
        let active = (note?.floats ?? false) || (note?.allSpaces ?? false)
        pinButton?.setSymbol(active ? "pin.fill" : "pin")
        layerButton?.setSymbol((note?.floats ?? false) ? "square.3.layers.3d.top.filled"
                               : (note?.behind ?? false) ? "square.3.layers.3d.bottom.filled" : "square.3.layers.3d")
    }

    /// The toolbar shows the reminder while one is set, otherwise the date of the last edit.
    func updateDate() {
        let note = store.notes[noteID]
        if let reminder = note?.reminder {
            dateLabel.stringValue = "🔔 " + Reminders.format(reminder)
            dateLabel.toolTip = "Reminder: " + Reminders.format(reminder)
        } else {
            let date = note?.modified ?? Date()
            let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
            dateLabel.stringValue = (sameYear ? Self.shortDate : Self.longDate).string(from: date)
            dateLabel.toolTip = "Last edited " + Reminders.format(date)
        }
        dateWidth?.constant = max(64, ceil(dateLabel.attributedStringValue.size().width) + 28)
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
    @objc private func searchClicked() { onSearch?() }

    @objc private func showSettingsMenu(_ sender: NSButton) {
        let menu = settingsMenu?() ?? NSMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    /// In front of other apps, as usual, or sunk onto the desktop behind everything.
    @objc private func showLayerMenu(_ sender: NSButton) {
        let note = store.notes[noteID]
        let menu = NSMenu()
        let choices: [(String, Selector, Bool)] = [
            ("In Front of Other Apps", #selector(layerFront), note?.floats ?? false),
            ("Normal", #selector(layerNormal), !(note?.floats ?? false) && !(note?.behind ?? false)),
            ("Behind Other Apps (on the Desktop)", #selector(layerBehind), note?.behind ?? false),
        ]
        for (title, action, on) in choices {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func layerFront() { setLayer(floats: true, behind: false) }
    @objc private func layerNormal() { setLayer(floats: false, behind: false) }
    @objc private func layerBehind() { setLayer(floats: false, behind: true) }
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

        menu.addItem(.separator())
        let row = NSMenuItem()
        let slider = OpacitySliderView(opacity: store.notes[noteID]?.opacity ?? 1)
        slider.onChange = { [weak self] value in self?.setOpacity(value) }
        row.view = slider
        menu.addItem(row)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func setOpacity(_ value: Double) {
        let opacity = Note.clampOpacity(value)
        store.update(noteID, touch: false) { $0.opacity = opacity }
        applyOpacity()
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

        menu.addItem(.separator())
        if let due = note?.reminder {
            let info = NSMenuItem(title: "Reminder: " + Reminders.format(due), action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            for (title, action) in [("Change Reminder…", #selector(remindMe)), ("Remove Reminder", #selector(clearReminder))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        } else {
            let remind = NSMenuItem(title: "Remind Me…", action: #selector(remindMe), keyEquivalent: "")
            remind.target = self
            menu.addItem(remind)
        }

        // Nine slots: ⌥⌘1 to ⌥⌘9 open the note in a slot from anywhere.
        menu.addItem(.separator())
        let slots = NSMenu()
        for slot in Note.slotRange {
            let holder = store.note(inSlot: slot)
            let suffix = holder.map { $0.id == noteID ? "" : "  (\($0.title))" } ?? ""
            let item = NSMenuItem(title: "Slot \(slot)  ⌥⌘\(slot)\(suffix)", action: #selector(slotChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = slot
            item.state = note?.slot == slot ? .on : .off
            slots.addItem(item)
        }
        if note?.slot != nil {
            slots.addItem(.separator())
            let remove = NSMenuItem(title: "Remove from Slot", action: #selector(slotChosen(_:)), keyEquivalent: "")
            remove.target = self
            remove.tag = 0
            slots.addItem(remove)
        }
        let slotItem = NSMenuItem(title: note?.slot.map { "Kept in Slot \($0)" } ?? "Keep in Slot", action: nil, keyEquivalent: "")
        slotItem.submenu = slots
        menu.addItem(slotItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func slotChosen(_ sender: NSMenuItem) {
        onSetSlot?(noteID, sender.tag == 0 ? nil : sender.tag)
    }

    /// Opens the reminder popover above the toolbar: a notification about this note appears then.
    @objc func remindMe() {
        if popover != nil { closePopover(); return }
        let note = store.notes[noteID]
        let view = ReminderView(
            noteTitle: note?.title ?? "",
            existing: note?.reminder,
            onSet: { [weak self] date in
                guard let self else { return }
                self.closePopover()
                self.onSetReminder?(self.noteID, date)
            },
            onRemove: { [weak self] in
                guard let self else { return }
                self.closePopover()
                self.onClearReminder?(self.noteID)
            })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]  // the popover is as big as the view needs
        present(host)
    }

    /// Shows `content` in a popover on the pin button, bringing the note and its toolbar up first.
    private func present(_ content: NSViewController) {
        if !isShown { show(focus: true) } else { window?.makeKeyAndOrderFront(nil) }
        setToolbarVisible(true, animated: false)
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient  // closes when you click elsewhere
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: pinButton.bounds, of: pinButton, preferredEdge: .maxY)
    }

    private func closePopover() {
        popover?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        if !isMouseInside { setToolbarVisible(false) }
    }

    @objc private func clearReminder() { onClearReminder?(noteID) }

    @objc private func toggleFloating() { setLayer(floats: !(store.notes[noteID]?.floats ?? false), behind: false) }
    @objc private func toggleAllSpaces() { setAllSpaces(!(store.notes[noteID]?.allSpaces ?? false)) }

    /// Window level: above other apps, normal, or just above the desktop icons (behind every other window).
    private func setLayer(floats: Bool, behind: Bool, persist: Bool = true) {
        let desktop = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window?.level = floats ? .floating : (behind ? desktop : .normal)
        if persist { store.update(noteID, touch: false) { $0.floats = floats; $0.behind = behind } }
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

    /// Don't underline things that aren't prose: mode keywords, variable names, code, link targets.
    func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        guard value != 0, affectedCharRange.location < storage.length else { return value }
        let skipped = storage.attribute(.deskNoSpell, at: affectedCharRange.location, effectiveRange: nil) != nil
        return skipped ? 0 : value
    }

    func textDidChange(_ notification: Notification) {
        let text = textView.string
        store.update(noteID) { $0.text = text }
        updateDate()
    }

    // MARK: Snapshot (`DeskNotes --snapshot <dir>`)

    /// Puts the caret at the end of the text, as if you had just typed it (shows the timer help).
    func placeCaretAtEnd() {
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

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
