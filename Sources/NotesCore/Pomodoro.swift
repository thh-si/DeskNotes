import Foundation

public struct PomodoroSettings: Equatable, Sendable {
    public var focus: TimeInterval = 25 * 60
    public var shortBreak: TimeInterval = 5 * 60
    public var longBreak: TimeInterval = 15 * 60
    /// A long break follows every n-th focus session.
    public var roundsBeforeLongBreak = 4

    public init() {}
}

/// A Pomodoro timer as a plain value: focus → short break → focus … → long break after every fourth
/// focus session. It never reads the clock; every call is given the current time, so a whole day of
/// sessions can be checked in a few lines, and sleeping or a stalled timer can't make it drift.
///
/// A break starts by itself when a focus session ends. After a break the timer waits (`idle`,
/// phase `focus`) until you start the next session.
public struct Pomodoro: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case focus, shortBreak, longBreak

        public var title: String {
            switch self {
            case .focus: return "Focus"
            case .shortBreak: return "Short break"
            case .longBreak: return "Long break"
            }
        }

        public var isBreak: Bool { self != .focus }
    }

    public enum State: Equatable, Sendable {
        case idle
        case running(endsAt: Date)
        case paused(remaining: TimeInterval)
    }

    public var settings: PomodoroSettings
    public private(set) var phase = Phase.focus
    public private(set) var state = State.idle
    /// Focus sessions finished since the app started or `reset()`.
    public private(set) var completedFocusSessions = 0

    public init(settings: PomodoroSettings = PomodoroSettings()) {
        self.settings = settings
    }

    public var isRunning: Bool { if case .running = state { return true } else { return false } }
    public var isPaused: Bool { if case .paused = state { return true } else { return false } }

    public func duration(of phase: Phase) -> TimeInterval {
        switch phase {
        case .focus: return settings.focus
        case .shortBreak: return settings.shortBreak
        case .longBreak: return settings.longBreak
        }
    }

    /// Time left in the current phase (the full length when idle).
    public func remaining(at now: Date) -> TimeInterval {
        switch state {
        case .idle: return duration(of: phase)
        case .running(let end): return max(0, end.timeIntervalSince(now))
        case .paused(let left): return left
        }
    }

    /// Starts the current phase from its full length. Does nothing if it is already running.
    public mutating func start(at now: Date) {
        guard state == .idle else { return }
        state = .running(endsAt: now.addingTimeInterval(duration(of: phase)))
    }

    public mutating func pause(at now: Date) {
        guard case .running = state else { return }
        state = .paused(remaining: remaining(at: now))
    }

    public mutating func resume(at now: Date) {
        guard case .paused(let left) = state else { return }
        state = .running(endsAt: now.addingTimeInterval(left))
    }

    /// Ends the current phase early, without counting a focus session as done: a skipped focus
    /// session moves on to the break, a skipped break back to waiting for the next focus session.
    public mutating func skip(at now: Date) {
        guard state != .idle else { return }
        if phase.isBreak {
            phase = .focus
            state = .idle
        } else {
            phase = .shortBreak  // a skipped session doesn't earn a long break
            state = .running(endsAt: now.addingTimeInterval(duration(of: phase)))
        }
    }

    /// Back to waiting for a focus session. Finished sessions stay counted.
    public mutating func stop() {
        phase = .focus
        state = .idle
    }

    public mutating func reset() {
        stop()
        completedFocusSessions = 0
    }

    /// Call regularly. When the running phase has ended it moves on and returns the phase that just
    /// finished, so the caller can announce it. Returns nil while nothing has finished.
    @discardableResult
    public mutating func tick(at now: Date) -> Phase? {
        guard case .running(let end) = state, now >= end else { return nil }
        let finished = phase
        if finished == .focus {
            completedFocusSessions += 1
            phase = completedFocusSessions % max(1, settings.roundsBeforeLongBreak) == 0 ? .longBreak : .shortBreak
            state = .running(endsAt: now.addingTimeInterval(duration(of: phase)))
        } else {
            phase = .focus
            state = .idle
        }
        return finished
    }

    /// `24:13`, `4:50`, `1:02:03`. Rounds up, so a fresh 25-minute session reads `25:00`.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
