import Foundation
import NotesCore

extension Notification.Name {
    static let fontSizeChanged = Notification.Name("DeskNotesFontSizeChanged")
    /// Spell checking / text replacement was switched in the Edit menu; open notes follow.
    static let textPrefsChanged = Notification.Name("DeskNotesTextPrefsChanged")
}

enum Settings {
    static var fontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: "fontSize")
            return stored == 0 ? 14 : CGFloat(min(max(stored, 10), 32))
        }
        set {
            UserDefaults.standard.set(Double(min(max(newValue, 10), 32)), forKey: "fontSize")
            NotificationCenter.default.post(name: .fontSizeChanged, object: nil)
        }
    }

    // MARK: Text checking (Edit menu)

    private static func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    private static func setFlag(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: .textPrefsChanged, object: nil)
    }

    /// Red underlines under misspelled words.
    static var spellChecking: Bool {
        get { flag("spellChecking", default: true) }
        set { setFlag("spellChecking", newValue) }
    }

    /// The text replacements from System Settings › Keyboard › Text Replacements.
    static var textReplacement: Bool {
        get { flag("textReplacement", default: true) }
        set { setFlag("textReplacement", newValue) }
    }

    /// Fixes misspelled words as you type. Off by default: it can rewrite `avg`, `desknotes` or a
    /// variable name before you have finished with it.
    static var autoCorrect: Bool {
        get { flag("autoCorrect", default: false) }
        set { setFlag("autoCorrect", newValue) }
    }

    // MARK: Pomodoro

    /// Lengths in minutes can be changed with `defaults write local.desknotes.app pomodoroFocusMinutes 50`
    /// (also `pomodoroShortBreakMinutes`, `pomodoroLongBreakMinutes`, `pomodoroRounds`).
    static var pomodoro: PomodoroSettings {
        var settings = PomodoroSettings()
        let defaults = UserDefaults.standard
        func minutes(_ key: String, _ fallback: TimeInterval) -> TimeInterval {
            let value = defaults.double(forKey: key)
            return (1...180).contains(value) ? value * 60 : fallback
        }
        settings.focus = minutes("pomodoroFocusMinutes", settings.focus)
        settings.shortBreak = minutes("pomodoroShortBreakMinutes", settings.shortBreak)
        settings.longBreak = minutes("pomodoroLongBreakMinutes", settings.longBreak)
        let rounds = defaults.integer(forKey: "pomodoroRounds")
        if (2...12).contains(rounds) { settings.roundsBeforeLongBreak = rounds }
        return settings
    }
}
