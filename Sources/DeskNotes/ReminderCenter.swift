import AppKit
import NotesCore

/// Keeps note reminders and the system's scheduled notifications in step.
///
/// - Setting a reminder stores it in the note *and* schedules a notification with macOS.
/// - When the notification is delivered (or clicked) the reminder is cleared from the note.
/// - At launch, reminders that came due while DeskNotes was not running are cleared; ones that were
///   never delivered are shown now, and future ones are scheduled again.
/// - While any note has a reminder, a timer watches for notifications being switched on or off in
///   System Settings, and shows the note itself when macOS didn't deliver a reminder (switched off,
///   or it could not be scheduled).
@MainActor
final class ReminderCenter {
    private let store: NoteStore
    private let notifier = Notifier.shared
    private var watchTimer: Timer?
    private var isChecking = false
    private var warnedAboutNotifications = false

    /// Bring this note to the front.
    var onShowNote: ((UUID) -> Void)?
    /// A note's reminder was set, changed, cleared or fired: its window should refresh.
    var onChanged: ((UUID) -> Void)?

    init(store: NoteStore) {
        self.store = store
        notifier.onReminderFired = { [weak self] id in self?.clearStored(id) }
        notifier.onOpenNote = { [weak self] id in self?.onShowNote?(id) }
    }

    // MARK: Launch

    func start() async {
        await notifier.refreshAuthorization()
        let delivered = await notifier.deliveredNoteIDs()
        let now = Date()

        for note in store.notes.values {
            guard let due = note.reminder else { continue }
            if due > now {
                await schedule(note, at: due)
            } else {
                clearStored(note.id)
                // Still in Notification Center: the user has seen it. Otherwise it was missed.
                if !delivered.contains(note.id) { await announce(note, missed: true) }
            }
        }
        updateWatchTimer()
    }

    // MARK: Setting and clearing

    func set(_ id: UUID, at date: Date) {
        store.update(id, touch: false) { $0.reminder = date }
        onChanged?(id)
        Task {
            if !notifier.isAuthorized { await notifier.requestAuthorization() }
            if let note = store.notes[id], note.reminder == date {
                if notifier.isAuthorized {
                    await schedule(note, at: date)
                } else {
                    warnNotificationsAreOff()
                }
            }
            updateWatchTimer()
        }
    }

    func clear(_ id: UUID) {
        notifier.cancelReminder(noteID: id)
        clearStored(id)
        updateWatchTimer()
    }

    /// Forget everything about a note that is being deleted.
    func forget(_ id: UUID) {
        notifier.cancelReminder(noteID: id)
        updateWatchTimer()
    }

    private func clearStored(_ id: UUID) {
        guard store.notes[id]?.reminder != nil else { return }
        store.update(id, touch: false) { $0.reminder = nil }
        onChanged?(id)
    }

    // MARK: Delivery

    private func schedule(_ note: Note, at date: Date) async {
        await notifier.scheduleReminder(noteID: note.id, title: "Reminder", body: note.title, at: date)
    }

    /// A reminder that came due without the system showing it: tell the user now.
    private func announce(_ note: Note, missed: Bool) async {
        let body = missed ? "\(note.title) (was due \(Reminders.format(note.reminder ?? Date())))" : note.title
        if await !notifier.post(title: "Reminder", body: body, noteID: note.id) {
            NSSound.beep()
            onShowNote?(note.id)
        }
    }

    // MARK: Watching for missed reminders

    /// Runs while any note has a reminder. The permission is read again on every tick, because the
    /// user can switch notifications on or off in System Settings while DeskNotes runs.
    private func updateWatchTimer() {
        let needed = store.notes.values.contains { $0.reminder != nil }
        if needed, watchTimer == nil {
            watchTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }  // timers fire on the main thread
            }
        } else if !needed {
            watchTimer?.invalidate()
            watchTimer = nil
        }
    }

    private func check() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            let wasAuthorized = notifier.isAuthorized
            await notifier.refreshAuthorization()
            // Just switched on: reminders set while they were off were never handed to macOS.
            if notifier.isAuthorized, !wasAuthorized {
                let now = Date()
                for note in store.notes.values {
                    if let due = note.reminder, due > now { await schedule(note, at: due) }
                }
            }
            showUndeliveredNotes()
            updateWatchTimer()
        }
    }

    /// A delivered reminder is cleared at once (`onReminderFired`), so one that is still set after
    /// its time never reached the screen. With notifications on, macOS gets a minute's grace.
    private func showUndeliveredNotes() {
        let cutoff = Date().addingTimeInterval(notifier.isAuthorized ? -60 : 0)
        for note in store.notes.values where Reminders.isDue(note, now: cutoff) {
            clearStored(note.id)
            NSSound.beep()
            onShowNote?(note.id)
        }
    }

    private func warnNotificationsAreOff() {
        guard !warnedAboutNotifications else { return }
        warnedAboutNotifications = true
        let alert = NSAlert()
        alert.messageText = "Notifications are off for DeskNotes"
        alert.informativeText = "While DeskNotes is running, the note will pop up and beep at the chosen time. "
            + "To get real notifications, even when DeskNotes is closed, allow them in System Settings › Notifications › DeskNotes."
        alert.runModal()
    }
}
