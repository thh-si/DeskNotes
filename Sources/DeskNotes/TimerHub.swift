import AppKit
import NotesCore

/// What the menu bar and the note's badge show for the timer that is running.
struct TimerDisplay: Equatable {
    /// `4:52`, `⏸ 4:52`, `Inhale 4:52`.
    var text: String
    /// The name given with `timer 5 : laundry`, or "Focus", "Short break" …
    var title: String
    var isPaused: Bool

    /// With the name in front, for the menu bar.
    var menuBarText: String { title.isEmpty ? text : title + " " + text }
}

/// One timer at a time: a stopwatch, countdown or breathing session from a `timer …` line, or the
/// Pomodoro. Starting one stops the other. It remembers which note started it, so that note can show
/// the badge.
@MainActor
final class TimerHub {
    let pomodoro = PomodoroController()
    private(set) var timer: NoteTimer?
    /// The note whose `timer` line started the running timer (nil when started from the menu).
    private(set) var originNote: UUID?

    /// The display changed: the menu bar and badges refresh.
    var onChange: (() -> Void)?

    private var ticker: Timer?
    private let notifier = Notifier.shared

    init() {
        pomodoro.onDisplayChange = { [weak self] _ in self?.changed() }
    }

    // MARK: Commands

    func run(_ command: TimerCommand, from noteID: UUID?) {
        let now = Date()
        switch command {
        case .stopwatch, .countdown, .breathe:
            guard let new = NoteTimer(command, startingAt: now) else { return }
            pomodoro.stop()
            timer = new
            originNote = noteID
            if new.total != nil { Task { if !notifier.isAuthorized { await notifier.requestAuthorization() } } }
            changed()
        case .pomodoro(let focus, let rest):
            timer = nil
            pomodoro.start(focus: focus, rest: rest)
            originNote = noteID
            changed()
        case .pause: pauseOrResume()
        case .reset: restart()
        case .stop: stop()
        }
    }

    func pauseOrResume() {
        if timer != nil {
            timer?.togglePause(at: Date())
            changed()
        } else if pomodoro.isActive {
            pomodoro.pauseOrResume()
        } else {
            NSSound.beep()
        }
    }

    func restart() {
        if timer != nil {
            timer?.restart(at: Date())
            changed()
        } else if pomodoro.isActive {
            pomodoro.restart()
        } else {
            NSSound.beep()
        }
    }

    func stop() {
        guard timer != nil || pomodoro.isActive else { NSSound.beep(); return }
        timer = nil
        pomodoro.stop()
        originNote = nil
        changed()
    }

    // MARK: Display

    var display: TimerDisplay? {
        let now = Date()
        if let timer {
            let clock = timer.clock(at: now)
            let text: String
            if let breath = timer.breath(at: now), timer.isRunning {
                text = breath.title + " " + clock
            } else {
                text = (timer.isPaused ? "⏸ " : "") + clock
            }
            return TimerDisplay(text: text, title: timer.label ?? "", isPaused: timer.isPaused)
        }
        if let text = pomodoro.displayText {
            return TimerDisplay(text: text, title: pomodoro.model.phase.title, isPaused: pomodoro.model.isPaused)
        }
        return nil
    }

    // MARK: Ticking

    private func changed() {
        let needsTicker = timer?.isRunning == true
        if needsTicker, ticker == nil {
            let new = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }  // timers fire on the main thread
            }
            RunLoop.main.add(new, forMode: .common)  // `.common`: keeps counting while a menu is open
            ticker = new
        } else if !needsTicker {
            ticker?.invalidate()
            ticker = nil
        }
        if pomodoro.isActive == false, timer == nil { originNote = nil }
        onChange?()
    }

    private func tick() {
        guard var current = timer else { return }
        let finished = current.tick(at: Date())
        timer = current
        if finished { announce(current) }
        if finished { timer = nil; originNote = nil }
        changed()
    }

    private func announce(_ finished: NoteTimer) {
        let title: String, body: String
        switch finished.kind {
        case .breathe:
            title = "Breathing session complete"
            body = "Take a moment before you carry on."
        default:
            title = finished.label.map { "\($0) is done" } ?? "Timer done"
            body = Pomodoro.clock(finished.total ?? 0) + " countdown finished."
        }
        Task {
            if await !notifier.post(title: title, body: body) { NSSound.beep() }
        }
    }
}
