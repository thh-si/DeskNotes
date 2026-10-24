import AppKit
import NotesCore
import SwiftUI

/// `DeskNotes --snapshot <dir>` (with `DESKNOTES_DIR` pointing at a scratch folder) renders a few
/// sample notes to PNG and exits. It exists to check the design without taking screenshots.
@MainActor
enum Snapshot {
    static let samples: [(name: String, text: String, theme: String, toolbar: Bool, opacity: Double)] = [
        ("list", "list\n\n# Break up lists with headers\nDoesn’t it feel good\nto check things off\njust type /x at the end of an item\nto check it off /x\nlike that ^\n\n## Second header\nanother item with a very long text that wraps onto the next line", "paper", false, 1),
        ("math", "math\n\nThe math keyword enables calculations.\n\nguests: 5\ncost per guest: $34\n\nguests * cost per guest =\n\nhourly rate: 23,75\ndaily earnings: hourly rate * 8 =\nmonthly salary: daily earnings * 20 =\n\n20% of 80 =\n100 + 20% =", "paper", true, 1),
        ("sum", "sum\n\nThis will add all of the numbers in the text.\n\n$2 for apples, $25 for bus tickets, $6 for coffee and $4,25 for a bagel.", "paper", false, 1),
        ("avg", "avg\n\nSame, but average.\n\n$2 for apples, $25 for bus tickets, $6 for coffee and $4,25 for a bagel.", "paper", false, 1),
        ("count", "count\nTed Bluderfield\nSadie Lafleur\nCarl Sagos\nAndrea Xi\nConnie Tinue", "paper", false, 1),
        ("welcome", NoteManager.welcome, "paper", false, 1),
        ("empty", "", "paper", true, 1),
        ("timer", "math\n\nWashing is on.\ntimer 5:30 : laundry", "paper", false, 1),
        ("timer-help", "timer pom", "paper", false, 1),
        ("translucent", "math\n\nA translucent note shows the desktop through a frosted blur.\n\n12 * 3 =", "yellow", true, 0.6),
        ("markdown", "# Heading\n## Sub heading\n### Third level\n**bold**, *italic*, ~~strike~~, ==highlight==, `code`\n{red|red} {blue|blue} {green|green} {#FF8800|hex}\n- bullet one\n- bullet two\n- [ ] open task\n- [x] done task\n> a quote\n12 * 3 =", "paper", false, 1),
        ("yellow-dark", "math\n\n12 * 3 =\n\n# Header\nlist-ish text", "graphite", false, 1),
    ]

    static func run(outputDir: String) {
        guard ProcessInfo.processInfo.environment["DESKNOTES_DIR"] != nil else {
            print("Refusing to run: set DESKNOTES_DIR to a scratch folder so your real notes are not touched.")
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = NoteStore.shared
        for (index, sample) in samples.enumerated() {
            var note = Note()
            note.text = sample.text
            note.themeID = sample.theme
            note.opacity = sample.opacity
            note.frame = CGRect(x: 120 + index * 10, y: 120, width: 440, height: sample.name == "welcome" ? 1180 : 560)
            store.add(note)
            let controller = NoteWindowController(note: note, store: store)
            if sample.name.hasPrefix("timer") { controller.placeCaretAtEnd() }
            if sample.name == "timer" {
                controller.setTimerDisplay(TimerDisplay(text: "4:52", title: "laundry", isPaused: false))
            }
            if let png = controller.snapshotPNG(showToolbar: sample.toolbar) {
                let file = dir.appendingPathComponent(String(format: "%02d-%@.png", index + 1, sample.name))
                try? png.write(to: file)
                print("wrote \(file.path)")
            } else {
                print("could not render \(sample.name)")
            }
            controller.window?.orderOut(nil)
        }

        // The All Notes window, with a few notes in slots.
        let ordered = store.notes.values.sorted { $0.created < $1.created }
        for (index, note) in ordered.prefix(3).enumerated() { store.assignSlot(index + 1, to: note.id) }
        let model = LibraryModel(store: store)
        model.isActive = true
        model.onOpen = { _ in }
        let states: [(String, LibraryLayout, LibraryScope, Bool)] = [
            ("library-list", .list, .all, false), ("library-cards", .grid, .all, false),
            ("library-slots", .list, .slotted, false), ("library-select", .list, .all, true)]
        for (name, layout, scope, selecting) in states {
            model.layout = layout
            model.scope = scope
            model.isSelecting = selecting
            if selecting { model.selection = Set(model.notes.prefix(2).map(\.id)) }
            write(NSHostingView(rootView: LibraryView(model: model)), size: NSSize(width: 540, height: 740),
                  to: dir.appendingPathComponent("\(name).png"))
        }

        // The content of the popover and menu rows, on a plain background (macOS draws the real frame).
        let reminder = NSHostingView(rootView: ReminderView(noteTitle: "Groceries · milk, eggs, bread", existing: Date().addingTimeInterval(7200),
                                                            onSet: { _ in }, onRemove: {}))
        write(reminder, size: reminder.fittingSize, to: dir.appendingPathComponent("reminder.png"))
        let slider = OpacitySliderView(opacity: 0.7)
        write(slider, size: slider.frame.size, to: dir.appendingPathComponent("opacity-slider.png"))

        // The menu bar glyph, enlarged 12x on white, to check its shape.
        let scale: CGFloat = 12
        let size = NSSize(width: 20 * scale, height: 18 * scale)
        let preview = NSImage(size: size)
        preview.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        AppIcon.statusImage().draw(in: NSRect(origin: .zero, size: size))
        preview.unlockFocus()
        if let tiff = preview.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("status-glyph.png"))
            print("wrote status-glyph.png")
        }
    }

    /// Draws `view` in a window and saves it as PNG.
    private static func write(_ view: NSView, size: NSSize, to file: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = view
        window.alphaValue = 0
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        view.displayIfNeeded()
        defer { window.orderOut(nil) }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print("wrote \(file.path)")
    }
}
