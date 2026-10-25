import AppKit
import NotesCore
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let timers: TimerHub
    private let manager: NoteManager
    private var pomodoro: PomodoroController { timers.pomodoro }
    private lazy var library = LibraryWindowController(manager: manager)
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()

    override init() {
        let hub = TimerHub()
        timers = hub
        manager = NoteManager(timers: hub)
        super.init()
    }

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
        // A copy opened from the disk image (or run by macOS from a temporary quarantine location)
        // gives way to the installed one, so the copy dragged to Applications is the one that runs.
        if !Self.isTemporaryCopy(Bundle.main.bundleURL), others.contains(where: { $0.bundleURL.map(Self.isTemporaryCopy) ?? false }) {
            DistributedNotificationCenter.default().postNotificationName(Self.yieldRequest, object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
        }
        if others.isEmpty {
            start()
        } else if Date() >= deadline {
            // The copy that is already running brings a note up, so opening the app is never silent.
            DistributedNotificationCenter.default().postNotificationName(Self.reopenRequest, object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
            NSApp.terminate(nil)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.startWhenOnlyCopy(deadline: deadline)
            }
        }
    }

    /// On a mounted disk image, or moved by macOS to a random read-only folder because the download
    /// was not yet allowed (App Translocation).
    private static func isTemporaryCopy(_ url: URL) -> Bool {
        url.path.hasPrefix("/Volumes/") || url.path.contains("/AppTranslocation/")
    }

    /// Sent by a second copy of the app that is about to quit, to the copy that keeps running.
    private static let reopenRequest = Notification.Name("local.desknotes.reopen")
    /// Sent by the installed copy to a temporary one (see `isTemporaryCopy`), which then quits.
    private static let yieldRequest = Notification.Name("local.desknotes.yield")

    /// Opening the app while it runs (Finder, Spotlight, the Dock) shows a note instead of nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        manager.bringUp()
        return false
    }

    private func start() {
        DistributedNotificationCenter.default().addObserver(forName: Self.reopenRequest, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.manager.bringUp() }
        }
        if Self.isTemporaryCopy(Bundle.main.bundleURL) {
            DistributedNotificationCenter.default().addObserver(forName: Self.yieldRequest, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
        Notifier.shared.start()  // first, so a click on a notification that launched us is received
        buildMainMenu()
        buildStatusItem()
        manager.onSearch = { [weak self] in self?.showLibrary() }
        manager.restore()
        Task { await manager.reminders.start() }

        HotKeyCenter.shared.register(keyCode: kVK_ANSI_N, modifiers: cmdKey | optionKey) { [weak self] in
            self?.manager.newNote()
        }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_J, modifiers: cmdKey | optionKey) { [weak self] in
            self?.manager.toggleAll()
        }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_L, modifiers: cmdKey | optionKey) { [weak self] in
            self?.library.show()
        }
        // ⌥⌘1 to ⌥⌘9: the notes kept in slots.
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, key) in digits.enumerated() {
            HotKeyCenter.shared.register(keyCode: key, modifiers: cmdKey | optionKey) { [weak self] in
                self?.manager.showSlot(index + 1)
            }
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
        timers.onChange = { [weak self] in self?.timersChanged() }
    }

    private func timersChanged() {
        showTimer(timers.display?.menuBarText)
        manager.refreshTimerBadges()
    }

    /// The countdown sits next to the menu bar icon while a timer or Pomodoro session is running.
    private func showTimer(_ text: String?) {
        guard let button = statusItem.button else { return }
        if let text {
            statusItem.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeft
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.title = " " + text
        } else {
            statusItem.length = NSStatusItem.squareLength
            button.imagePosition = .imageOnly
            button.title = ""
        }
    }

    private func pomodoroItem() -> NSMenuItem {
        let model = pomodoro.model
        let holder = NSMenuItem(title: "Timer" + (timers.display.map { " · " + $0.menuBarText } ?? ""),
                                action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Timer")
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        func note(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if let timer = timers.timer {
            // A stopwatch, countdown or breathing session from a `timer …` line.
            note("\(timer.label ?? "Timer") – \(timer.clock(at: Date()))")
            menu.addItem(.separator())
            add(timer.isPaused ? "Resume" : "Pause", #selector(timerPauseOrResume))
            add("Start Again", #selector(timerRestart))
            add("Stop", #selector(timerStop))
        } else {
            switch model.state {
            case .idle:
                add("Start Focus (\(Int(model.settings.focus / 60)) min)", #selector(pomodoroStart))
            case .running, .paused:
                note("\(model.phase.title) – \(Pomodoro.clock(model.remaining(at: Date()))) left")
                menu.addItem(.separator())
                add(model.isPaused ? "Resume" : "Pause", #selector(pomodoroPauseOrResume))
                add(model.phase.isBreak ? "Skip Break" : "Skip to Break", #selector(pomodoroSkip))
                add("Stop", #selector(pomodoroStop))
            }
            if model.completedFocusSessions > 0 {
                menu.addItem(.separator())
                note("Focus sessions done: \(model.completedFocusSessions)")
            }
        }
        menu.addItem(.separator())
        note("In a note: type “timer 5” and press Return")
        holder.submenu = menu
        return holder
    }

    @objc private func timerPauseOrResume() { timers.pauseOrResume() }
    @objc private func timerRestart() { timers.restart() }
    @objc private func timerStop() { timers.stop() }
    @objc private func pomodoroStart() { pomodoro.start() }
    @objc private func pomodoroPauseOrResume() { pomodoro.pauseOrResume() }
    @objc private func pomodoroSkip() { pomodoro.skip() }
    @objc private func pomodoroStop() { pomodoro.stop() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        menu.removeAllItems()

        let new = NSMenuItem(title: "New Note", action: #selector(newNote), keyEquivalent: "n")
        new.keyEquivalentModifierMask = [.command, .option]
        let toggle = NSMenuItem(title: "Show / Hide All Notes", action: #selector(toggleAll), keyEquivalent: "j")
        toggle.keyEquivalentModifierMask = [.command, .option]
        let all = NSMenuItem(title: "All Notes…", action: #selector(showLibrary), keyEquivalent: "l")
        all.keyEquivalentModifierMask = [.command, .option]
        for item in [new, toggle, all] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(pomodoroItem())

        // Text and checking options (every note follows them).
        menu.addItem(.separator())
        func option(_ title: String, _ action: Selector, on: Bool? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let on { item.state = on ? .on : .off }
            menu.addItem(item)
        }
        let size = NSMenuItem(title: "Text Size: \(Int(Settings.fontSize)) pt", action: nil, keyEquivalent: "")
        size.isEnabled = false
        menu.addItem(size)
        option("Bigger Text", #selector(biggerText))
        option("Smaller Text", #selector(smallerText))
        option("Check Spelling While Typing", #selector(toggleSpelling), on: Settings.spellChecking)
        option("Use Text Replacements", #selector(toggleReplacements), on: Settings.textReplacement)
        option("Correct Spelling Automatically", #selector(toggleAutocorrect), on: Settings.autoCorrect)

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

        // The version, so a bug report can say which build it is.
        let info = Bundle.main.infoDictionary
        if let version = info?["CFBundleShortVersionString"] as? String {
            let channel = (info?["DeskNotesChannel"] as? String).map { " (\($0))" } ?? ""
            let versionItem = NSMenuItem(title: "DeskNotes \(version)\(channel)", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            menu.addItem(.separator())
            menu.addItem(versionItem)
        }

        let quit = NSMenuItem(title: "Quit DeskNotes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func showLibrary() { library.show() }

    @objc private func toggleSpelling() { Settings.spellChecking.toggle() }
    @objc private func toggleReplacements() { Settings.textReplacement.toggle() }
    @objc private func toggleAutocorrect() { Settings.autoCorrect.toggle() }
    @objc private func newNote() { manager.newNote() }
    @objc private func toggleAll() { manager.toggleAll() }
    @objc private func newWelcomeNote() { manager.newWelcomeNote() }

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
    @objc private func deleteFrontNote() { manager.frontController?.deleteNote() }
    @objc private func remindFrontNote() { manager.frontController?.remindMe() }

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
            item("All Notes…", #selector(showLibrary), "l", [.command, .option], target: self),
            item("Search Notes…", #selector(showLibrary), "f", target: self),
            item("Hide Note", #selector(NSWindow.performClose(_:)), "w"),
            item("Remind Me…", #selector(remindFrontNote), "r", [.command, .option], target: self),
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
            .separator(),
            // Standard text-view actions: macOS fills in the checkmarks for the note you are typing in.
            item("Check Spelling Now", #selector(NSText.checkSpelling(_:)), ";"),
            item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"),
            item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
            item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))),
            item("Use Text Replacements", #selector(NSTextView.toggleAutomaticTextReplacement(_:))),
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
