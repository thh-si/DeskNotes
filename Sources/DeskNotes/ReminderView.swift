import SwiftUI
import NotesCore

/// The date being edited. A plain observable object rather than `@State`: in current SDKs `@State`
/// is a macro whose compiler plugin only comes with full Xcode, and DeskNotes builds with just the
/// Command Line Tools.
@MainActor
final class ReminderModel: ObservableObject {
    @Published var date: Date
    /// The month the calendar shows (its first day).
    @Published var month: Date

    init(date: Date) {
        self.date = date
        month = Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
    }

    /// Picks a day and keeps the time of day that is already set.
    func choose(day: Date) {
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: date)
        date = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }

    /// Picks an exact moment (a quick choice) and shows its month.
    func choose(moment: Date) {
        date = moment
        month = Calendar.current.dateInterval(of: .month, for: moment)?.start ?? moment
    }
}

/// The reminder popover: quick choices, a calendar and a time, and a line saying exactly what will
/// happen. Buttons and fields are standard controls, so macOS draws them in its current style
/// (Liquid Glass on macOS 26 and later).
struct ReminderView: View {
    let noteTitle: String
    let existing: Date?
    let onSet: @MainActor (Date) -> Void
    let onRemove: @MainActor () -> Void

    @ObservedObject private var model: ReminderModel
    private let presets: [Reminders.Preset]
    private let now: Date

    init(noteTitle: String, existing: Date?, now: Date = Date(),
         onSet: @escaping @MainActor (Date) -> Void, onRemove: @escaping @MainActor () -> Void) {
        self.noteTitle = noteTitle
        self.existing = existing
        self.now = now
        self.onSet = onSet
        self.onRemove = onRemove
        presets = Reminders.presets(now: now)
        model = ReminderModel(date: existing.flatMap { $0 > now ? $0 : nil } ?? Reminders.defaultDate(now: now))
    }

    private var hasPassed: Bool { model.date <= Date() }

    private var relative: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: model.date, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            quickChoices
            MonthGrid(model: model, now: now)
            HStack {
                Label("Time", systemImage: "clock")
                    .foregroundStyle(.secondary)
                Spacer()
                DatePicker("Time", selection: $model.date, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
            }
            summary
            actions
        }
        .padding(18)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Remind me")
                    .font(.headline)
                Text(noteTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var quickChoices: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
            ForEach(presets, id: \.date) { preset in
                Button {
                    model.choose(moment: preset.date)
                } label: {
                    VStack(spacing: 1) {
                        Text(preset.title)
                            .font(.callout.weight(.medium))
                        Text(Self.time(preset.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(model.date == preset.date ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// `18:00`, or `Mon 09:00` when it is not today.
    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let clock = formatter.string(from: date)
        guard !Calendar.current.isDateInToday(date) else { return clock }
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("EEE")
        return day.string(from: date) + " " + clock
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Image(systemName: hasPassed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(hasPassed ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(hasPassed ? "That time has already passed" : Reminders.format(model.date))
                    .font(.callout.weight(.semibold))
                if !hasPassed {
                    Text(relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var actions: some View {
        HStack {
            if existing != nil {
                Button("Remove", role: .destructive) { onRemove() }
            }
            Spacer()
            Button("Set Reminder") {
                // Whole minutes: the notification and the label then agree.
                onSet(Calendar.current.date(bySetting: .second, value: 0, of: model.date) ?? model.date)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(hasPassed)
        }
        .controlSize(.large)
    }
}

/// A month calendar that fills the width. Days before today can't be picked.
struct MonthGrid: View {
    @ObservedObject var model: ReminderModel
    let now: Date

    private var calendar: Calendar { .current }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    /// One entry per grid cell: empty cells before the 1st, then every day of the month.
    private var cells: [Date?] {
        guard let first = calendar.dateInterval(of: .month, for: model.month)?.start,
              let days = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading)
            + (0..<days).map { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    private var canGoBack: Bool {
        guard let thisMonth = calendar.dateInterval(of: .month, for: now)?.start else { return false }
        return model.month > thisMonth
    }

    private func shiftMonth(by value: Int) {
        model.month = calendar.date(byAdding: .month, value: value, to: model.month) ?? model.month
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(model.month.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()
                Button { shiftMonth(by: -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(!canGoBack)
                Button { shiftMonth(by: 1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 30)
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: model.date)
        let isToday = calendar.isDateInToday(day)
        let isPast = day < calendar.startOfDay(for: now)
        return Button {
            model.choose(day: day)
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 13, weight: isSelected || isToday ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white : isToday ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    if isSelected { Circle().fill(Color.accentColor).padding(1) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPast)
        .opacity(isPast ? 0.3 : 1)
    }
}
