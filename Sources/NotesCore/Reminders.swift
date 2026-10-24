import Foundation

/// Date helpers for note reminders.
public enum Reminders {
    public struct Preset: Equatable, Sendable {
        public let title: String
        public let date: Date
    }

    /// The next full hour: what the date picker starts on.
    public static func defaultDate(now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(3600)
    }

    /// Quick choices for the reminder dialog, soonest first. Choices that would fall in the past
    /// (an evening reminder at 19:30) or coincide with an earlier one (next Monday, when today is
    /// Sunday) are left out.
    public static func presets(now: Date, calendar: Calendar = .current) -> [Preset] {
        var result: [Preset] = []
        func add(_ title: String, _ date: Date?) {
            guard let date, date > now, !result.contains(where: { $0.date == date }) else { return }
            result.append(Preset(title: title, date: date))
        }
        func at(hour: Int, after reference: Date, weekday: Int? = nil) -> Date? {
            calendar.nextDate(after: reference,
                              matching: DateComponents(hour: hour, minute: 0, second: 0, weekday: weekday),
                              matchingPolicy: .nextTime)
        }

        // Whole minutes, so the notification and the label agree.
        let inOneHour = now.addingTimeInterval(3600)
        add("In 1 hour", calendar.date(bySetting: .second, value: 0, of: inOneHour))
        if let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now), evening > now.addingTimeInterval(15 * 60) {
            add("This evening", evening)
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        add("Tomorrow morning", tomorrow.flatMap { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) })
        add("Next Monday", at(hour: 9, after: now, weekday: 2))
        return result.sorted { $0.date < $1.date }
    }

    public static func isDue(_ note: Note, now: Date) -> Bool {
        guard let reminder = note.reminder else { return false }
        return reminder <= now
    }

    /// "Today at 15:00", "Tomorrow at 09:00", "21 Oct 2026 at 09:00": relative names where the
    /// system has them, in the user's language.
    public static func format(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}
