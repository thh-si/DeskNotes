import AppKit
import NotesCore
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let manager = NoteManager()
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        startWhenOnlyCopy(deadline: Date().addingTimeInterval(3))
    }

    /// Only one copy may run, otherwise two apps fight over the hot keys. A copy that is just
    /// shutting down (update, relaunch) gets up to 3 seconds to disappear; this checks again every
    /// 0.1 s without blocking the main thread.
    private func startWhenOnlyCopy(deadline: Date) {
        let others = Bundle.main.bundleIdentifier.map { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0 != NSRunningApplication.current && !$0.isTerminated }
        } ?? []
        if others.isEmpty {
            start()
        } else if Date() >= deadline {
            NSApp.terminate(nil)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.startWhenOnlyCopy(deadline: deadline)
            }
        }
    }

    private func start() {
        buildMainMenu()
        buildStatusItem()
        manager.restore()

        HotKeyCenter.shared.register(keyCode: kVK_ANSI_N, modifiers: cmdKey | optionKey) { [weak self] in
            self?.manager.newNote()
        }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_J, modifiers: cmdKey | optionKey) { [weak self] in
            self?.manager.toggleAll()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.store.flush()
    }

    // MARK: Status item (menu bar)

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = AppIcon.statusImage()
            button.toolTip = "DeskNotes"
        }
        statusMenu.delegate = self
        statusItem.menu = statusMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        menu.removeAllItems()

        let new = NSMenuItem(title: "New Note", action: #selector(newNote), keyEquivalent: "n")
        new.keyEquivalentModifierMask = [.command, .option]
        let toggle = NSMenuItem(title: "Show / Hide All Notes", action: #selector(toggleAll), keyEquivalent: "j")
        toggle.keyEquivalentModifierMask = [.command, .option]
        for item in [new, toggle] {
            item.target = self
            menu.addItem(item)
        }

        let notes = manager.store.notes.values.sorted { $0.modified > $1.modified }
        menu.addItem(.separator())
        if notes.isEmpty {
            let none = NSMenuItem(title: "No notes yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            let header = NSMenuItem(title: "Notes", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for note in notes.prefix(20) {
                let item = NSMenuItem(title: note.title, action: #selector(showNote(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = note.id
                item.image = NoteTheme.named(note.themeID).swatch
                item.state = manager.isShown(note.id) ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let welcome = NSMenuItem(title: "New Welcome Note", action: #selector(newWelcomeNote), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed
        default: login.state = .off
        }
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit DeskNotes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func newNote() { manager.newNote() }
    @objc private func toggleAll() { manager.toggleAll() }
    @objc private func newWelcomeNote() { manager.newWelcomeNote() }

    @objc private func showNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.show(id)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText = "Launch at Login only works when DeskNotes runs as an app from the Applications folder.\n\n" + error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: Main menu
    // An accessory app shows no menu bar, but its key equivalents (⌘C, ⌘V, ⌘B …) still need this menu.

    @objc private func biggerText() { Settings.fontSize += 1 }
    @objc private func smallerText() { Settings.fontSize -= 1 }
    @objc private func deleteFrontNote() {
        (NSApp.keyWindow?.windowController as? NoteWindowController)?.deleteNote()
    }

    private func buildMainMenu() {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach { menu.addItem($0) }
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }

        submenu("DeskNotes", [
            item("Quit DeskNotes", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("New Note", #selector(newNote), "n", target: self),
            item("Hide Note", #selector(NSWindow.performClose(_:)), "w"),
            // ⌥⌘⌫, not ⌘⌫: in text, ⌘⌫ means "delete to the start of the line".
            item("Delete Note…", #selector(deleteFrontNote), String(UnicodeScalar(NSBackspaceCharacter)!),
                 [.command, .option], target: self),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])

        let colorHolder = NSMenuItem(title: "Text Colour", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu(title: "Text Colour")
        for name in ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "gray"] {
            let c = NSMenuItem(title: name.capitalized, action: #selector(NoteTextView.applyTextColor(_:)), keyEquivalent: "")
            c.representedObject = name
            colorMenu.addItem(c)
        }
        colorHolder.submenu = colorMenu

        submenu("Format", [
            item("Bold", #selector(NoteTextView.toggleBold(_:)), "b"),
            item("Italic", #selector(NoteTextView.toggleItalic(_:)), "i"),
            item("Strikethrough", #selector(NoteTextView.toggleStrikethrough(_:)), "x", [.command, .shift]),
            item("Highlight", #selector(NoteTextView.toggleHighlight(_:)), "h", [.command, .shift]),
            item("Code", #selector(NoteTextView.toggleCode(_:)), "k", [.command, .shift]),
            colorHolder,
            .separator(),
            item("Bigger Text", #selector(biggerText), "+", target: self),
            item("Smaller Text", #selector(smallerText), "-", target: self),
        ])

        NSApp.mainMenu = main
    }
}
