import AppKit
import NotesCore

/// Owns all note windows and decides which are shown.
@MainActor
final class NoteManager {
    let store: NoteStore
    let reminders: ReminderCenter
    let timers: TimerHub
    private var controllers: [UUID: NoteWindowController] = [:]
    private var hiddenByToggle: [UUID] = []
    /// Set by the app: the All Notes window, and the menu behind the settings button of a note.
    var onSearch: (() -> Void)?
    var settingsMenu: (() -> NSMenu)?

    init(store: NoteStore = .shared, timers: TimerHub) {
        self.store = store
        self.timers = timers
        reminders = ReminderCenter(store: store)
        reminders.onShowNote = { [weak self] id in self?.show(id) }
        reminders.onChanged = { [weak self] id in self?.controllers[id]?.updateDate() }
    }

    /// Shows the running timer on the note that started it, and on no other.
    func refreshTimerBadges() {
        let display = timers.display
        for (id, controller) in controllers {
            controller.setTimerDisplay(timers.originNote == id ? display : nil)
        }
    }

    /// The window of the note you are working in, if any.
    var frontController: NoteWindowController? {
        NSApp.keyWindow?.windowController as? NoteWindowController
    }

    /// The first note. Every example in it works where it stands: click at the end of a line.
    static let welcome = """
    # Welcome to DeskNotes

    Quick notes on your desktop, always one keystroke away.

    ## Basics
    - ⌥⌘N  new note, from any app
    - ⌥⌘J  show or hide all notes
    - ⌥⌘L  all notes: search and delete
    - ⌘W  hide a note (the menu bar has it)
    - Hover a note to see its toolbar

    ## Calculate
    End a line with = and the result appears. Tab or Return writes it into the note.

    89 * 3 =
    20% of 80 =
    100 + 20% =

    Give a value a name with a colon:

    guests: 5
    cost per guest: $34
    guests * cost per guest =

    ## Note types
    Put one word alone on the first line:

    - list  a checklist, add /x to tick
    - sum  adds every number
    - avg  their average
    - count  words and readability

    ## Timers
    Click at the end of a line and press Return:

    timer 5
    timer 5:30 : laundry
    timer pomo

    Also timer p (pause), r (reset), s (stop) and breathe.

    ## Reminders, slots, colour
    - Pin button: remind me, or keep the note in a slot (⌥⌘1 to ⌥⌘9 opens it)
    - Palette button: colour and opacity
    - ⌘+ and ⌘-  text size

    ## Formatting
    **bold**  *italic*  ~~strike~~  ==mark==
    `code`  [link](https://example.com)
    {red|colour}  {#FF8800|any hex}
    """

    func restore() {
        store.load()
        if store.notes.isEmpty && !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            _ = createNote(text: Self.welcome, size: CGSize(width: 440, height: 720))
        }
        for note in store.notes.values.sorted(by: { $0.created < $1.created }) {
            let controller = makeController(for: note)
            if note.isVisible { controller.show(focus: false) }
        }
    }

    func newNote() {
        addNote(text: "", size: CGSize(width: 400, height: 480))
    }

    func newWelcomeNote() {
        addNote(text: Self.welcome, size: CGSize(width: 440, height: 720))
    }

    /// Adds a note to the store only (no window yet).
    private func createNote(text: String, size: CGSize) -> Note {
        var note = Note()
        note.text = text
        note.frame = defaultFrame(size: size)
        store.add(note)
        return note
    }

    private func addNote(text: String, size: CGSize) {
        let note = createNote(text: text, size: size)
        makeController(for: note).show(focus: true)
    }

    func show(_ id: UUID) {
        controllers[id]?.show(focus: true)
    }

    /// Deletes notes (their files go to the Trash). Used by the All Notes window.
    func deleteNotes(_ ids: [UUID]) {
        ids.forEach { delete($0) }
    }

    /// Puts a note in slot 1 to 9, or takes it out (nil).
    func setSlot(_ slot: Int?, for id: UUID) {
        store.assignSlot(slot, to: id)
    }

    /// Opens the note in a slot: ⌥⌘1 to ⌥⌘9 from anywhere.
    func showSlot(_ slot: Int) {
        guard let note = store.note(inSlot: slot) else {
            NSSound.beep()
            return
        }
        show(note.id)
    }

    func isShown(_ id: UUID) -> Bool { controllers[id]?.isShown ?? false }

    /// Hides every visible note; calling it again brings those same notes back.
    func toggleAll() {
        let visible = controllers.filter { $0.value.isShown }
        if !visible.isEmpty {
            hiddenByToggle = Array(visible.keys)
            visible.values.forEach { $0.hideTemporarily() }
        } else {
            let ids = hiddenByToggle.isEmpty ? Array(controllers.keys) : hiddenByToggle
            hiddenByToggle = []
            for id in ids { controllers[id]?.show(focus: id == ids.last) }
        }
    }

    private func delete(_ id: UUID) {
        if let controller = controllers.removeValue(forKey: id) {
            controller.window?.delegate = nil
            controller.window?.orderOut(nil)
            controller.close()
        }
        reminders.forget(id)
        store.remove(id)
    }

    @discardableResult
    private func makeController(for note: Note) -> NoteWindowController {
        var note = note
        note.frame = Self.validFrame(note.frame) ?? defaultFrame(size: note.frame.size)
        let controller = NoteWindowController(note: note, store: store)
        controller.onNewNote = { [weak self] in self?.newNote() }
        controller.onSearch = { [weak self] in self?.onSearch?() }
        controller.settingsMenu = { [weak self] in self?.settingsMenu?() ?? NSMenu() }
        controller.onDelete = { [weak self] id in self?.delete(id) }
        controller.onSetReminder = { [weak self] id, date in self?.reminders.set(id, at: date) }
        controller.onClearReminder = { [weak self] id in self?.reminders.clear(id) }
        controller.onSetSlot = { [weak self] id, slot in self?.setSlot(slot, for: id) }
        controller.onTimerCommand = { [weak self] id, command in self?.timers.run(command, from: id) }
        controller.onTimerToggle = { [weak self] in self?.timers.pauseOrResume() }
        controller.onTimerStop = { [weak self] in self?.timers.stop() }
        controllers[note.id] = controller
        return controller
    }

    /// Notes saved on a monitor that is gone now would be unreachable; put them back on screen.
    private static func validFrame(_ frame: CGRect) -> CGRect? {
        let reachable = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width >= 80 && overlap.height >= 40
        }
        return reachable ? frame : nil
    }

    private func defaultFrame(size: CGSize) -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let step = CGFloat(store.notes.count % 8) * 26
        let height = min(size.height, area.height - 60)
        return CGRect(x: area.maxX - size.width - 40 - step,
                      y: area.maxY - height - 30 - step,
                      width: size.width, height: height)
    }
}
