import Foundation

/// A timer line typed in a note: `timer`, `timer 5`, `timer 5:30 : laundry`, `timer pomo`,
/// `timer 52 17`, `timer p` / `r` / `s`, `timer breathe`. Return on the line starts it.
public enum TimerCommand: Equatable, Sendable {
    case stopwatch(label: String?)
    case countdown(seconds: TimeInterval, label: String?)
    /// Lengths in seconds; nil uses the standard 25 / 5 minutes (or what was set with `defaults`).
    case pomodoro(focus: TimeInterval?, rest: TimeInterval?)
    case breathe
    /// Pause, or resume when paused.
    case pause
    /// Start again from the beginning.
    case reset
    case stop

    /// The longest countdown: a day.
    public static let maxSeconds: TimeInterval = 24 * 3600

    /// Reads a whole line. Anything that is not exactly a timer command gives nil, so ordinary text
    /// that happens to start with "timer" is left alone.
    public static func parse(_ line: String) -> TimerCommand? {
        guard line.utf16.count <= 200 else { return nil }  // no real command is this long
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("timer") else { return nil }
        let afterWord = text.dropFirst(5)
        guard afterWord.isEmpty || afterWord.first!.isWhitespace else { return nil }
        var rest = String(afterWord).trimmingCharacters(in: .whitespaces)

        // A name comes after a colon that has a space beside it: `5:30 : laundry`, `5: laundry`.
        var label: String?
        if let separator = rest.range(of: #"\s+:\s*|:\s+"#, options: .regularExpression) {
            let name = String(rest[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            label = name.isEmpty ? nil : name
            rest = String(rest[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        let words = rest.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return .stopwatch(label: label) }

        // Words that take no name.
        if label == nil, words.count == 1 {
            switch first {
            case "p", "pause", "resume": return .pause
            case "r", "reset": return .reset
            case "s", "stop": return .stop
            case "breathe", "breath": return .breathe
            case "pomo", "pomodoro": return .pomodoro(focus: nil, rest: nil)
            default: break
            }
        }
        if label == nil, first == "pomo" || first == "pomodoro" {
            let lengths = words.dropFirst().map(minutes)
            guard lengths.count == 2, let focus = lengths[0], let rest = lengths[1] else { return nil }
            return .pomodoro(focus: focus, rest: rest)
        }
        // `52 17`: two plain numbers are a custom Pomodoro (focus and break, in minutes).
        if label == nil, words.count == 2, let focus = minutes(words[0]), let rest = minutes(words[1]) {
            return .pomodoro(focus: focus, rest: rest)
        }
        guard let seconds = duration(rest) else { return nil }
        return .countdown(seconds: seconds, label: label)
    }

    /// `5`, `1.5`, `1,5`: minutes, between 1 and 180.
    private static func minutes(_ word: String) -> TimeInterval? {
        guard word.range(of: #"^\d+([.,]\d+)?$"#, options: .regularExpression) != nil,
              let value = Double(word.replacingOccurrences(of: ",", with: ".")),
              (1...180).contains(value) else { return nil }
        return value * 60
    }

    /// A length of time: `5` (minutes), `5:30` (minutes and seconds), `1:05:00`, `90s`, `10 min`,
    /// `1h30m`. Nil if it isn't one, is zero, or is longer than a day.
    public static func duration(_ text: String) -> TimeInterval? {
        let text = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var seconds: TimeInterval?

        if text.range(of: #"^\d+(:\d{1,2}){1,2}$"#, options: .regularExpression) != nil {
            let parts = text.split(separator: ":").map { Double($0) ?? 0 }
            guard parts.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
            seconds = parts.count == 2 ? parts[0] * 60 + parts[1] : parts[0] * 3600 + parts[1] * 60 + parts[2]
        } else if text.range(of: #"^\d+([.,]\d+)?$"#, options: .regularExpression) != nil {
            seconds = Double(text.replacingOccurrences(of: ",", with: ".")).map { $0 * 60 }
        } else {
            // Numbers with units, which must make up the whole text: `1h30m`, `90 sec`.
            let compact = text.filter { !$0.isWhitespace }
            guard compact.range(of: #"^(\d+([.,]\d+)?[a-z]+)+$"#, options: .regularExpression) != nil else { return nil }
            let part = try! NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)([a-z]+)"#)
            var total = 0.0
            for match in part.matches(in: compact, range: NSRange(compact.startIndex..., in: compact)) {
                guard let number = Range(match.range(at: 1), in: compact), let unit = Range(match.range(at: 2), in: compact),
                      let value = Double(compact[number].replacingOccurrences(of: ",", with: ".")) else { return nil }
                switch compact[unit] {
                case "h", "hr", "hrs", "hour", "hours": total += value * 3600
                case "m", "min", "mins", "minute", "minutes": total += value * 60
                case "s", "sec", "secs", "second", "seconds": total += value
                default: return nil
                }
            }
            seconds = total
        }
        guard let seconds, seconds > 0, seconds <= maxSeconds else { return nil }
        return seconds
    }

    // MARK: Help text

    /// What Return will do, for the line being typed.
    public func hint(pomodoro defaults: PomodoroSettings = PomodoroSettings()) -> String {
        func name(_ label: String?) -> String { label.map { "“\($0)”: " } ?? "" }
        switch self {
        case .stopwatch(let label): return "Enter to start a \(name(label))stopwatch."
        case .countdown(let seconds, let label): return "Enter to start a \(name(label))\(Pomodoro.clock(seconds)) countdown."
        case .pomodoro(let focus, let rest):
            let f = Int((focus ?? defaults.focus) / 60), r = Int((rest ?? defaults.shortBreak) / 60)
            return "Enter to start a \(f)m/\(r)m pomodoro."
        case .breathe: return "Enter to start 5 minutes of slow breathing."
        case .pause: return "Enter to pause or resume the timer."
        case .reset: return "Enter to start the timer again from the beginning."
        case .stop: return "Enter to stop the timer."
        }
    }

    /// Shown under a `timer` line that is not complete yet.
    public static let cheatSheet = [
        "timer 5 – to countdown",
        "timer 5:30 : laundry – to name a countdown",
        "timer pomo – to start a 25m/5m pomodoro",
        "timer 52 17 – a custom pomodoro of 52m/17m",
        "timer p – pause / resume",
        "timer r – reset",
        "timer s – stop",
        "timer breathe – to chill",
        "Click the timer to pause, double-click to stop.",
    ]

    /// Whether a line is on its way to being a timer command (so the help should show).
    public static func isTimerLine(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces).lowercased()
        return text == "timer" || text.hasPrefix("timer ")
    }
}

/// A stopwatch, countdown or breathing session. Like `Pomodoro`, it never reads the clock itself.
public struct NoteTimer: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case stopwatch
        case countdown(TimeInterval)
        case breathe(TimeInterval)
    }

    public enum Breath: Equatable, Sendable {
        case inhale, exhale

        public var title: String { self == .inhale ? "Inhale" : "Exhale" }
    }

    public static let breatheSession: TimeInterval = 5 * 60
    /// In for 4 seconds, out for 6.
    public static let inhaleSeconds: TimeInterval = 4
    public static let exhaleSeconds: TimeInterval = 6

    public let kind: Kind
    public let label: String?
    public private(set) var isFinished = false
    private var accumulated: TimeInterval = 0
    private var runningSince: Date?

    public init(kind: Kind, label: String? = nil, startingAt now: Date) {
        self.kind = kind
        self.label = label
        runningSince = now
    }

    public init?(_ command: TimerCommand, startingAt now: Date) {
        switch command {
        case .stopwatch(let label): self.init(kind: .stopwatch, label: label, startingAt: now)
        case .countdown(let seconds, let label): self.init(kind: .countdown(seconds), label: label, startingAt: now)
        case .breathe: self.init(kind: .breathe(Self.breatheSession), label: nil, startingAt: now)
        default: return nil
        }
    }

    public var isRunning: Bool { runningSince != nil }
    public var isPaused: Bool { runningSince == nil && !isFinished }

    /// The length of a countdown or breathing session; nil for a stopwatch.
    public var total: TimeInterval? {
        switch kind {
        case .stopwatch: return nil
        case .countdown(let seconds), .breathe(let seconds): return seconds
        }
    }

    public func elapsed(at now: Date) -> TimeInterval {
        accumulated + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    public func remaining(at now: Date) -> TimeInterval? {
        total.map { max(0, $0 - elapsed(at: now)) }
    }

    /// Where in the breathing cycle a `breathe` session is; nil for other kinds.
    public func breath(at now: Date) -> Breath? {
        guard case .breathe = kind else { return nil }
        let cycle = Self.inhaleSeconds + Self.exhaleSeconds
        return elapsed(at: now).truncatingRemainder(dividingBy: cycle) < Self.inhaleSeconds ? .inhale : .exhale
    }

    public mutating func pause(at now: Date) {
        guard runningSince != nil else { return }
        accumulated = elapsed(at: now)
        runningSince = nil
    }

    public mutating func resume(at now: Date) {
        guard runningSince == nil, !isFinished else { return }
        runningSince = now
    }

    public mutating func togglePause(at now: Date) {
        if isRunning { pause(at: now) } else { resume(at: now) }
    }

    /// Back to the beginning, running.
    public mutating func restart(at now: Date) {
        accumulated = 0
        isFinished = false
        runningSince = now
    }

    /// Call regularly. Returns true once, when a countdown or breathing session has just ended.
    @discardableResult
    public mutating func tick(at now: Date) -> Bool {
        guard isRunning, let total, elapsed(at: now) >= total else { return false }
        accumulated = total
        runningSince = nil
        isFinished = true
        return true
    }

    /// The time to show: counting down for countdowns and breathing, up for a stopwatch.
    public func clock(at now: Date) -> String {
        Pomodoro.clock(remaining(at: now) ?? elapsed(at: now))
    }
}
