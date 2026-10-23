import AppKit
import NotesCore

/// `DeskNotes --snapshot <dir>` (with `DESKNOTES_DIR` pointing at a scratch folder) renders a few
/// sample notes to PNG and exits. It exists to check the design without taking screenshots.
enum Snapshot {
    static let samples: [(name: String, text: String, theme: String, toolbar: Bool)] = [
        ("list", "list\n\n# Break up lists with headers\nDoesn’t it feel good\nto check things off\njust type /x at the end of an item\nto check it off /x\nlike that ^\n\n## Second header\nanother item with a very long text that wraps onto the next line", "paper", false),
        ("math", "math\n\nThe math keyword enables calculations.\n\nguests: 5\ncost per guest: $34\n\nguests * cost per guest =\n\nhourly rate: 23,75\ndaily earnings: hourly rate * 8 =\nmonthly salary: daily earnings * 20 =\n\n20% of 80 =\n100 + 20% =", "paper", true),
        ("sum", "sum\n\nThis will add all of the numbers in the text.\n\n$2 for apples, $25 for bus tickets, $6 for coffee and $4,25 for a bagel.", "paper", false),
        ("avg", "avg\n\nSame, but average.\n\n$2 for apples, $25 for bus tickets, $6 for coffee and $4,25 for a bagel.", "paper", false),
        ("count", "count\nTed Bluderfield\nSadie Lafleur\nCarl Sagos\nAndrea Xi\nConnie Tinue", "paper", false),
        ("markdown", "# Heading\n## Sub heading\n### Third level\n**bold**, *italic*, ~~strike~~, ==highlight==, `code`\n{red|red} {blue|blue} {green|green} {#FF8800|hex}\n- bullet one\n- bullet two\n- [ ] open task\n- [x] done task\n> a quote\n12 * 3 =", "paper", false),
        ("yellow-dark", "math\n\n12 * 3 =\n\n# Header\nlist-ish text", "graphite", false),
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
            note.frame = CGRect(x: 120 + index * 10, y: 120, width: 420, height: 560)
            store.add(note)
            let controller = NoteWindowController(note: note, store: store)
            if let png = controller.snapshotPNG(showToolbar: sample.toolbar) {
                let file = dir.appendingPathComponent(String(format: "%02d-%@.png", index + 1, sample.name))
                try? png.write(to: file)
                print("wrote \(file.path)")
            } else {
                print("could not render \(sample.name)")
            }
            controller.window?.orderOut(nil)
        }

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
}
