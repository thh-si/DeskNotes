import AppKit
import NotesCore

/// Owns all note windows and decides which are shown.
final class NoteManager {
    let store = NoteStore.shared
    private var controllers: [UUID: NoteWindowController] = [:]
    private var hiddenByToggle: [UUID] = []

    static let welcome = """
    math

    Welcome to DeskNotes. Notes stay on your desktop – ⌘W only hides one; bring it back from the menu bar icon.

    Type a calculation, end the line with = and the result appears. Tab or Return writes it into the note:

    89 * 3 =
    20% of 80 =
    100 + 20% =

    Variables use a colon and can have spaces in their name:

    guests: 5
    cost per guest: $34
    guests * cost per guest =

    # Modes
    Start a note with one of these words on its own line:
    list – a checklist, add /x to tick an item
    sum – adds all numbers in the note
    avg – their average
    count – words, sentences, readability

    ## Markdown
    **bold**, *italic*, ~~strike~~, ==highlight==, `code`
    {red|red}, {blue|blue}, {green|green}, {#FF8800|any #hex}

    ⌥⌘N new note · ⌥⌘J show / hide all · ⌘+ ⌘- text size
    """

    func restore() {
        store.load()
        if store.notes.isEmpty && !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            _ = createNote(text: Self.welcome, size: CGSize(width: 420, height: 640))
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
        addNote(text: Self.welcome, size: CGSize(width: 420, height: 640))
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
        store.remove(id)
    }

    @discardableResult
    private func makeController(for note: Note) -> NoteWindowController {
        var note = note
        note.frame = Self.validFrame(note.frame) ?? defaultFrame(size: note.frame.size)
        let controller = NoteWindowController(note: note, store: store)
        controller.onNewNote = { [weak self] in self?.newNote() }
        controller.onDelete = { [weak self] id in self?.delete(id) }
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
