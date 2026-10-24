import AppKit
import NotesCore

/// Runs the `Pomodoro` timer: ticks once a second while it is running, tells the menu bar what to
/// show, and sends a notification when a focus session or a break ends.
@MainActor
final class PomodoroController {
    private(set) var model: Pomodoro
    private var timer: Timer?
    private let notifier = Notifier.shared

    /// What to show next to the menu bar icon (`24:13`, `Break 4:50`, `⏸ 12:00`), or nil when idle.
    var onDisplayChange: ((String?) -> Void)?

    init(settings: PomodoroSettings = Settings.pomodoro) {
        model = Pomodoro(settings: settings)
    }

    // MARK: Commands

    /// Lengths in seconds; nil uses the standard ones (or what was set with `defaults write`).
    func start(focus: TimeInterval? = nil, rest: TimeInterval? = nil) {
        var settings = Settings.pomodoro
        if let focus { settings.focus = focus }
        if let rest {
            settings.shortBreak = rest
            settings.longBreak = rest * 3  // the same 1 : 3 as the standard 5 and 15 minutes
        }
        model.settings = settings
        model.stop()
        model.start(at: Date())
        Task { if !notifier.isAuthorized { await notifier.requestAuthorization() } }
        changed()
    }

    func pauseOrResume() {
        if model.isRunning { model.pause(at: Date()) } else { model.resume(at: Date()) }
        changed()
    }

    /// Back to the start of a focus session.
    func restart() {
        model.stop()
        model.start(at: Date())
        changed()
    }

    var isActive: Bool { model.state != .idle }

    func skip() {
        model.skip(at: Date())
        changed()
    }

    func stop() {
        model.stop()
        changed()
    }

    // MARK: State for the menu

    var displayText: String? {
        let now = Date()
        let clock = Pomodoro.clock(model.remaining(at: now))
        switch model.state {
        case .idle: return nil
        case .paused: return "⏸ " + clock
        case .running: return model.phase.isBreak ? "Break " + clock : clock
        }
    }

    // MARK: Timer

    private func changed() {
        if model.isRunning, timer == nil {
            // `.common`, so the countdown also moves while a menu is open.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }  // timers fire on the main thread
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !model.isRunning {
            timer?.invalidate()
            timer = nil
        }
        onDisplayChange?(displayText)
    }

    private func tick() {
        if let finished = model.tick(at: Date()) { announce(finished) }
        changed()
    }

    private func announce(_ finished: Pomodoro.Phase) {
        let title: String, body: String
        if finished == .focus {
            let minutes = Int(model.duration(of: model.phase) / 60)
            title = "Focus session done"
            body = "\(model.phase.title) for \(minutes) min. \(model.completedFocusSessions) done so far."
        } else {
            title = "\(finished.title) over"
            body = "Ready for the next focus session? Start it from the menu bar."
        }
        Task {
            if await !notifier.post(title: title, body: body) { NSSound.beep() }
        }
    }
}
