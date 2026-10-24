import Foundation
import NotesCore

var failures = 0
var total = 0

let us = Locale(identifier: "en_US")
let de = Locale(identifier: "de_DE")

@MainActor func expectValue(_ expression: String, _ expected: Double, tolerance: Double = 1e-9) {
    total += 1
    do {
        let got = try Calculator().evaluate(expression)
        if abs(got - expected) > tolerance {
            failures += 1
            print("FAIL  \(expression) = \(got), expected \(expected)")
        }
    } catch {
        failures += 1
        print("FAIL  \(expression) threw \(error), expected \(expected)")
    }
}

@MainActor func expectError(_ expression: String) {
    total += 1
    if let got = try? Calculator().evaluate(expression) {
        failures += 1
        print("FAIL  \(expression) = \(got), expected an error")
    }
}

@MainActor func expectEqual<T: Equatable>(_ got: T, _ expected: T, _ label: String) {
    total += 1
    if got != expected {
        failures += 1
        print("FAIL  \(label): got \(got), expected \(expected)")
    }
}

// MARK: expressions
expectValue("12*3", 36)
expectValue("2+3*4", 14)
expectValue("(2+3)*4", 20)
expectValue("2^3^2", 512)
expectValue("-2^2", -4)
expectValue("2^-1", 0.5)
expectValue("10/4", 2.5)
expectValue("10 mod 3", 1)
expectValue("sqrt(16)", 4)
expectValue("max(1, 5, 3)", 5)
expectValue("max(1; 5; 3)", 5)
expectValue("min(4,2)", 2)
expectValue("round(2.567, 2)", 2.57)
expectValue("$12 + $8", 20)
expectValue("5k * 2", 10000)
expectValue("1e3 + 1", 1001)
expectValue("pi", Double.pi)
expectValue("3 × 4 ÷ 2", 6)
expectValue("log(1000)", 3)
// percentages
expectValue("100 + 20%", 120)
expectValue("100 - 20%", 80)
expectValue("20% of 50", 10)
expectValue("50 * 10%", 5)
expectValue("10%", 0.1)
// errors
expectError("1/0")
expectError("12*")
expectError("foo + 1")
expectError("sqrt(-1)")
expectError("2 +* 3")

// decimal comma
do {
    let calc = Calculator(decimalComma: true)
    expectEqual(try? calc.evaluate("23,75 * 2"), 47.5, "decimal comma")
    expectEqual(try? calc.evaluate("23.75 * 2"), 47.5, "decimal point still works")
    expectEqual(try? calc.evaluate("max(1;5;3)"), 5, "semicolon arguments")
}

// MARK: formatting
expectEqual(Calculator.format(0.1 + 0.2, locale: us), "0.30", "format 0.1+0.2")
expectEqual(Calculator.format(36, locale: us), "36.00", "format int")
expectEqual(Calculator.format(-0.0, locale: us), "0.00", "format -0")
expectEqual(Calculator.format(1234.5, locale: us), "1,234.50", "format grouping")
expectEqual(Calculator.format(3800, locale: de), "3.800,00", "format german")
expectEqual(Calculator.format(170, currency: "$", locale: de), "$170,00", "format currency")
expectEqual(Calculator.format(-5, currency: "$", locale: us), "-$5.00", "format negative currency")
expectEqual(Calculator.format(0.001, locale: us), "0.001", "format tiny value")

// MARK: note analysis
func values(_ text: String, _ locale: Locale = us) -> [Double] { NoteCalculator.analyze(text, locale: locale).results.map(\.value) }

expectEqual(values("12 * 3 ="), [36], "inline")
expectEqual(values("12*3="), [36], "inline without space")
expectEqual(values("no math here"), [], "plain text")
expectEqual(values("x = 5\ny = x * 2 ="), [5, 10], "variables with =")
expectEqual(values("x: 5\ny: x * 2 ="), [5, 10], "variables with colon")
expectEqual(NoteCalculator.analyze("x = 5", locale: us).results.first?.showsGhost, false, "trivial assignment has no ghost")
expectEqual(NoteCalculator.analyze("x = 5*2", locale: us).results.first?.showsGhost, true, "computed assignment has ghost")
expectEqual(values("10\n20\nsum ="), [30], "sum")
expectEqual(values("- 10\n- 20\navg ="), [15], "avg over list items")
expectEqual(values("1\n2\n\n5\nsum ="), [5], "sum resets at blank line")
expectEqual(values("- 3 + 4 ="), [7], "list prefix is ignored")
expectEqual(values("## 2 * 2 ="), [4], "heading prefix is ignored")
expectEqual(values("a = 2\nA * 4 ="), [2, 8], "variables are case-insensitive")

// the examples from the Antinote tour
let tour = "math\nguests: 5\ncost per guest: $34\nguests * cost per guest ="
let tourResult = NoteCalculator.analyze(tour, locale: us)
expectEqual(tourResult.mode, .math, "math keyword")
expectEqual(tourResult.results.last?.value, 170, "multi-word variables")
expectEqual(tourResult.results.last?.display, "$170.00", "currency carried from variable")
expectEqual(tourResult.labels.count, 2, "variable labels")
if let label = tourResult.labels.first {
    expectEqual((tour as NSString).substring(with: label.name), "guests", "label name range")
    expectEqual((tour as NSString).substring(with: label.separator), ":", "label separator range")
}
let salary = "hourly rate: 23,75\ndaily earnings: hourly rate * 8 =\nmonthly salary: daily earnings * 20 ="
expectEqual(values(salary, de), [23.75, 190, 3800], "german decimal comma variables")
expectEqual(NoteCalculator.analyze(salary, locale: de).results.last?.display, "3.800,00", "german display")

// keywords
expectEqual(NoteCalculator.analyze("list\na\nb", locale: us).mode, .list, "list keyword")
expectEqual(NoteCalculator.analyze("List: Groceries\na", locale: us).mode, .list, "list keyword with title, any case")
expectEqual(NoteCalculator.analyze("summary of things", locale: us).mode, .plain, "keyword must stand alone")
expectEqual(NoteCalculator.analyze("sum of things", locale: us).mode, .plain, "keyword must stand alone (sum)")

// list
let list = NoteCalculator.analyze("list\n# Head\nmilk\neggs /x\n\nbread", locale: us)
expectEqual(list.listItems.count, 3, "list items skip headings and blanks")
expectEqual(list.listItems.map(\.isDone), [false, true, false], "list done state")
expectEqual(list.listItems[1].doneMarker?.length, 3, "done marker includes the space")

// sum / avg / count
let money = "sum\n$2 for apples, $25 for bus tickets, $6 for coffee and $4.25 for a bagel."
expectEqual(NoteCalculator.analyze(money, locale: us).output.first?.text, "Total: $37.25", "sum")
expectEqual(NoteCalculator.analyze(money.replacingOccurrences(of: "sum", with: "avg"), locale: us).output.first?.text,
            "Avg: $9.31", "avg")
expectEqual(NoteCalculator.analyze("sum\n$2 and $4,25", locale: de).output.first?.text, "Total: $6,25", "sum with decimal comma")
let names = NoteCalculator.analyze("count\nTed Bluderfield\nSadie Lafleur\nCarl Sagos\nAndrea Xi\nConnie Tinue", locale: us)
expectEqual(names.output.map(\.text).prefix(4).map { $0 }, ["Items: 5", "Words: 10", "Characters: 63", "Sentences: 5"], "count")
expectEqual(names.output.count, 6, "count shows readability scores")

let multi = NoteCalculator.analyze("hello\n12 * 3 =\n", locale: us)
expectEqual(multi.results.first?.range, NSRange(location: 6, length: 8), "line range")

// MARK: nesting limit (deep input must fail cleanly, not overflow the stack)
func nested(_ depth: Int) -> String { String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth) }
expectValue(nested(100), 1)
expectError(nested(50_000))
expectError(String(repeating: "-", count: 50_000) + "1")
expectValue(String(repeating: "-", count: 10) + "1", 1)
expectEqual(NoteCalculator.analyze(nested(50_000) + " =", locale: us).results.count, 0, "deep line is skipped")

// MARK: formatter cache keeps locales and digit settings apart
expectEqual([Calculator.format(1234.5, locale: us), Calculator.format(1234.5, locale: de), Calculator.format(1234.5, locale: us)],
            ["1,234.50", "1.234,50", "1,234.50"], "formatter cache per locale")
expectEqual([Calculator.format(0.001, locale: us), Calculator.format(2, locale: us)], ["0.001", "2.00"], "formatter cache per digits")

// MARK: links
func scheme(_ target: String) -> String? { LinkPolicy.url(for: target)?.scheme?.lowercased() }
expectEqual(scheme("https://example.com/a"), "https", "https link")
expectEqual(scheme("http://example.com"), "http", "http link")
expectEqual(LinkPolicy.url(for: "example.com/page")?.absoluteString, "https://example.com/page", "bare domain gets https")
expectEqual(LinkPolicy.url(for: "mailto:a@b.de")?.absoluteString, "mailto:a@b.de", "mailto link")
expectEqual(LinkPolicy.url(for: "file:///Applications/Calculator.app"), nil, "file link blocked")
expectEqual(LinkPolicy.url(for: "smb://server/share"), nil, "smb link blocked")
expectEqual(LinkPolicy.url(for: "x-apple.systempreferences://com.apple.preference"), nil, "app scheme blocked")
expectEqual(["https", nil].contains(scheme("javascript:alert(1)")), true, "pseudo scheme never opens as itself")

// MARK: note store
let emptyNote = try? JSONDecoder().decode(Note.self, from: Data("{}".utf8))
expectEqual(emptyNote?.themeID, Note().themeID, "missing theme gets the new-note default")

do {
    let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    let dir = tmp.appendingPathComponent("DeskNotesChecks-\(UUID().uuidString)")
    defer { chmod(dir.path, 0o755); try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(directory: dir)
    expectEqual(FileManager.default.fileExists(atPath: dir.path), true, "store creates its folder")
    var note = Note()
    note.text = "keep me"
    store.add(note)

    chmod(dir.path, 0o555)  // read-only: the save must fail
    store.flush()
    expectEqual(store.hasUnsavedChanges, true, "failed save stays pending")
    expectEqual(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(note.id.uuidString).json").path),
                false, "nothing written to read-only folder")

    chmod(dir.path, 0o755)
    store.flush()
    expectEqual(store.hasUnsavedChanges, false, "retried save succeeds")
    let reloaded = NoteStore(directory: dir)
    reloaded.load()
    expectEqual(reloaded.notes[note.id]?.text, "keep me", "saved note reloads")
}

// MARK: list prefixes (shared by calculator, styler and editor)
let task = ListPrefix.match(in: "  - [x] done")
expectEqual(task?.range, NSRange(location: 0, length: 8), "task prefix range")
expectEqual(task?.indent.length, 2, "task indent")
expectEqual(task?.box, NSRange(location: 4, length: 3), "task box")
expectEqual(task?.isChecked, true, "task checked")
expectEqual(ListPrefix.match(in: "12) item")?.marker, NSRange(location: 0, length: 3), "numbered marker")
expectEqual(ListPrefix.match(in: "- [ ]")?.box != nil, true, "box at end of line")
expectEqual(ListPrefix.match(in: "- [x](link)")?.box, nil, "link label is no checkbox")
expectEqual(ListPrefix.match(in: "-3 + 4"), nil, "negative number is no list")
expectEqual(NoteMode.keywords, ["math", "list", "sum", "avg", "count"], "mode keywords")
var keywordNote = Note()
keywordNote.text = "sum\n$4 coffee"
expectEqual(keywordNote.title, "sum · $4 coffee", "keyword title uses shared keyword list")

// MARK: file format version
let newer = Data(#"{"format": 99, "text": "from the future"}"#.utf8)
expectEqual((try? JSONDecoder().decode(Note.self, from: newer)) == nil, true, "newer format is refused")
let legacy = try? JSONDecoder().decode(Note.self, from: Data(#"{"text": "old"}"#.utf8))
expectEqual(legacy?.format, Note.currentFormat, "file without format loads as current")

// MARK: store: renamed files, newer files
do {
    let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    let dir = tmp.appendingPathComponent("DeskNotesChecks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = NoteStore(directory: dir)
    let fm = FileManager.default
    var renamed = Note()
    renamed.text = "before"
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try? encoder.encode(renamed).write(to: dir.appendingPathComponent("My note.json"))
    try? newer.write(to: dir.appendingPathComponent("future.json"))

    let store = NoteStore(directory: dir)
    store.load()
    expectEqual(store.notes.count, 1, "newer-format file is not loaded")
    store.update(renamed.id) { $0.text = "after" }
    store.flush()
    let names = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
    expectEqual(names, ["My note.json", "future.json"], "renamed file is saved in place, no duplicate")
    expectEqual(try? Data(contentsOf: dir.appendingPathComponent("future.json")), newer, "newer-format file left untouched")
    let again = NoteStore(directory: dir)
    again.load()
    expectEqual(again.notes[renamed.id]?.text, "after", "renamed file reloads with the edit")
}

// MARK: translucency and reminder fields
func decodeNote(_ json: String) -> Note? { try? JSONDecoder().decode(Note.self, from: Data(json.utf8)) }
expectEqual(decodeNote("{}")?.opacity, 1.0, "opacity defaults to solid")
expectEqual(decodeNote(#"{"opacity": 0.1}"#)?.opacity, Note.opacityRange.lowerBound, "too transparent is limited")
expectEqual(decodeNote(#"{"opacity": 7}"#)?.opacity, 1.0, "opacity above 1 is limited")
expectEqual(decodeNote(#"{"opacity": 0.7}"#)?.opacity, 0.7, "opacity kept")
expectEqual(Note.clampOpacity(.nan), 1.0, "NaN opacity")
expectEqual(Note.opacityPresets.allSatisfy { Note.opacityRange.contains($0) }, true, "presets are within range")
expectEqual(decodeNote("{}")?.reminder, nil, "no reminder by default")
do {
    var note = Note()
    note.reminder = Date(timeIntervalSince1970: 1_800_000_000)
    note.opacity = 0.55
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let back = (try? encoder.encode(note)).flatMap { try? decoder.decode(Note.self, from: $0) }
    expectEqual(back?.reminder, note.reminder, "reminder survives saving")
    expectEqual(back?.opacity, 0.55, "opacity survives saving")
    expectEqual(Reminders.isDue(note, now: Date(timeIntervalSince1970: 1_800_000_001)), true, "reminder due")
    expectEqual(Reminders.isDue(note, now: Date(timeIntervalSince1970: 1_799_999_999)), false, "reminder not yet due")
    expectEqual(Reminders.isDue(Note(), now: Date()), false, "no reminder is never due")
}

// MARK: reminder dates (fixed calendar and clock: Friday 23 Oct 2026, 14:30 UTC)
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
@MainActor func day(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
}
let friday = day(23, 14, 30)
expectEqual(Reminders.defaultDate(now: friday, calendar: utc), day(23, 15), "default is the next full hour")
expectEqual(Reminders.defaultDate(now: day(23, 15), calendar: utc), day(23, 16), "on the hour: the following hour")
let fridayPresets = Reminders.presets(now: friday, calendar: utc)
expectEqual(fridayPresets.map(\.title), ["In 1 hour", "This evening", "Tomorrow morning", "Next Monday"], "presets on a Friday")
expectEqual(fridayPresets.map(\.date), [day(23, 15, 30), day(23, 18), day(24, 9), day(26, 9)], "preset dates")
expectEqual(Reminders.presets(now: day(23, 19, 30), calendar: utc).map(\.title).contains("This evening"), false, "no evening preset after 18:00")
expectEqual(Reminders.presets(now: day(25, 10), calendar: utc).map(\.title), ["In 1 hour", "This evening", "Tomorrow morning"], "Sunday: tomorrow is Monday, no duplicate")
expectEqual(Reminders.presets(now: friday, calendar: utc).allSatisfy { $0.date > friday }, true, "presets are in the future")
expectEqual(Reminders.format(friday, locale: us).isEmpty, false, "reminder text")

// MARK: Pomodoro (fake clock)
let t0 = Date(timeIntervalSince1970: 1_000_000)
func after(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
do {
    var p = Pomodoro()
    expectEqual(p.state, .idle, "starts idle")
    expectEqual(p.remaining(at: t0), 25 * 60, "idle shows the full session")
    p.start(at: t0)
    expectEqual(p.isRunning, true, "running after start")
    expectEqual(p.remaining(at: after(60)), 24 * 60, "one minute in")
    expectEqual(p.tick(at: after(1499)), nil, "not finished a second early")
    expectEqual(p.tick(at: after(1500)), .focus, "focus finishes on time")
    expectEqual(p.phase, .shortBreak, "short break follows")
    expectEqual(p.isRunning, true, "break starts by itself")
    expectEqual(p.completedFocusSessions, 1, "one session counted")
    expectEqual(p.remaining(at: after(1500)), 5 * 60, "break length")
    expectEqual(p.tick(at: after(1800)), .shortBreak, "break finishes")
    expectEqual(p.state, .idle, "waits for the next session")
    expectEqual(p.phase, .focus, "next is focus")

    // pause and resume keep the time that was left
    var q = Pomodoro()
    q.start(at: t0)
    q.pause(at: after(100))
    expectEqual(q.state, .paused(remaining: 1400), "paused keeps remaining time")
    expectEqual(q.tick(at: after(99_999)), nil, "a paused timer never finishes")
    q.resume(at: after(500))
    expectEqual(q.remaining(at: after(500)), 1400, "resume continues")
    expectEqual(q.tick(at: after(500 + 1399)), nil, "resumed: not early")
    expectEqual(q.tick(at: after(500 + 1400)), .focus, "resumed: finishes after the rest")
    q.start(at: after(0))  // already running: ignored
    expectEqual(q.phase, .shortBreak, "start while running does nothing")

    // a long break after every fourth focus session
    var r = Pomodoro()
    var clock = 0.0
    var breaks: [Pomodoro.Phase] = []
    for _ in 1...8 {
        r.start(at: after(clock)); clock += 1500
        r.tick(at: after(clock))
        breaks.append(r.phase)
        clock += r.duration(of: r.phase)
        r.tick(at: after(clock))
    }
    expectEqual(breaks, [.shortBreak, .shortBreak, .shortBreak, .longBreak, .shortBreak, .shortBreak, .shortBreak, .longBreak], "long break every 4th session")
    expectEqual(r.completedFocusSessions, 8, "eight sessions counted")

    // skipping
    var s = Pomodoro()
    s.skip(at: t0)
    expectEqual(s.state, .idle, "skip while idle does nothing")
    s.start(at: t0)
    s.skip(at: after(10))
    expectEqual(s.phase, .shortBreak, "skipping focus goes to the break")
    expectEqual(s.completedFocusSessions, 0, "a skipped session does not count")
    s.skip(at: after(20))
    expectEqual(s.phase, .focus, "skipping the break goes back to focus")
    expectEqual(s.state, .idle, "…and waits")
    s.start(at: after(30)); s.tick(at: after(30 + 1500)); s.stop()
    expectEqual(s.state, .idle, "stop")
    expectEqual(s.completedFocusSessions, 1, "stop keeps the count")
    s.reset()
    expectEqual(s.completedFocusSessions, 0, "reset clears the count")

    // settings
    var custom = PomodoroSettings()
    custom.focus = 50 * 60; custom.roundsBeforeLongBreak = 2
    var c = Pomodoro(settings: custom)
    c.start(at: t0)
    expectEqual(c.remaining(at: t0), 3000, "custom focus length")
    c.tick(at: after(3000)); c.tick(at: after(3000 + 300))
    c.start(at: after(4000)); c.tick(at: after(4000 + 3000))
    expectEqual(c.phase, .longBreak, "long break after 2 when set to 2")

    // a long sleep: the timer moves one phase at a time
    var d = Pomodoro()
    d.start(at: t0)
    expectEqual(d.tick(at: after(100_000)), .focus, "after sleeping the finished phase is reported")
    expectEqual(d.remaining(at: after(100_000)), 300, "the break starts from the wake-up time")
}
expectEqual(Pomodoro.clock(1500), "25:00", "clock full session")
expectEqual(Pomodoro.clock(0.2), "0:01", "clock rounds up")
expectEqual(Pomodoro.clock(0), "0:00", "clock zero")
expectEqual(Pomodoro.clock(-5), "0:00", "clock never negative")
expectEqual(Pomodoro.clock(3723), "1:02:03", "clock with hours")

// MARK: typed timer commands
func cmd(_ line: String) -> TimerCommand? { TimerCommand.parse(line) }
expectEqual(cmd("timer"), .stopwatch(label: nil), "bare timer is a stopwatch")
expectEqual(cmd("  Timer  "), .stopwatch(label: nil), "case and spaces")
expectEqual(cmd("timer : cooking"), .stopwatch(label: "cooking"), "named stopwatch")
expectEqual(cmd("timer 5"), .countdown(seconds: 300, label: nil), "5 minutes")
expectEqual(cmd("timer 1.5"), .countdown(seconds: 90, label: nil), "decimal minutes")
expectEqual(cmd("timer 1,5"), .countdown(seconds: 90, label: nil), "decimal comma")
expectEqual(cmd("timer 5:30"), .countdown(seconds: 330, label: nil), "minutes:seconds")
expectEqual(cmd("timer 1:05:00"), .countdown(seconds: 3900, label: nil), "hours:minutes:seconds")
expectEqual(cmd("timer 5:30 : laundry"), .countdown(seconds: 330, label: "laundry"), "named countdown")
expectEqual(cmd("timer 5: laundry day"), .countdown(seconds: 300, label: "laundry day"), "name with a space after the colon")
expectEqual(cmd("timer 5 : "), .countdown(seconds: 300, label: nil), "empty name")
expectEqual(cmd("timer 90s"), .countdown(seconds: 90, label: nil), "seconds unit")
expectEqual(cmd("timer 10 min"), .countdown(seconds: 600, label: nil), "minutes unit with space")
expectEqual(cmd("timer 1h30m"), .countdown(seconds: 5400, label: nil), "hours and minutes")
expectEqual(cmd("timer 1h 30m 15s"), .countdown(seconds: 5415, label: nil), "all units with spaces")
expectEqual(cmd("timer 2 hours"), .countdown(seconds: 7200, label: nil), "word units")
expectEqual(cmd("timer pomo"), .pomodoro(focus: nil, rest: nil), "pomodoro")
expectEqual(cmd("timer Pomodoro"), .pomodoro(focus: nil, rest: nil), "pomodoro, long form")
expectEqual(cmd("timer 52 17"), .pomodoro(focus: 3120, rest: 1020), "custom pomodoro")
expectEqual(cmd("timer pomo 50 10"), .pomodoro(focus: 3000, rest: 600), "pomo with lengths")
expectEqual(cmd("timer p"), .pause, "pause")
expectEqual(cmd("timer pause"), .pause, "pause, long form")
expectEqual(cmd("timer r"), .reset, "reset")
expectEqual(cmd("timer s"), .stop, "stop")
expectEqual(cmd("timer breathe"), .breathe, "breathe")
// things that are not commands stay text
expectEqual(cmd("timer broken, buy a new one"), nil, "prose is not a command")
expectEqual(cmd("timers 5"), nil, "timers is another word")
expectEqual(cmd("timer0"), nil, "no space")
expectEqual(cmd("my timer 5"), nil, "must start the line")
expectEqual(cmd("timer 0"), nil, "zero is no timer")
expectEqual(cmd("timer 25:00:01"), nil, "longer than a day")
expectEqual(cmd("timer 5:75"), nil, "seconds above 59")
expectEqual(cmd("timer 5m30"), nil, "number without unit in a unit list")
expectEqual(cmd("timer 5 xyz"), nil, "unknown unit")
expectEqual(cmd("timer 500 17"), nil, "pomodoro longer than 3 hours")
expectEqual(cmd("timer pomo 25"), nil, "pomo with one length")
expectEqual(cmd("timer p now"), nil, "extra word after p")
expectEqual(cmd("timer -5"), nil, "negative")
expectEqual(TimerCommand.isTimerLine("timer pom"), true, "partial command shows the help")
expectEqual(TimerCommand.isTimerLine("timers"), false, "timers is not a timer line")
expectEqual(cmd("timer 5")?.hint(), "Enter to start a 5:00 countdown.", "countdown hint")
expectEqual(cmd("timer pomo")?.hint(), "Enter to start a 25m/5m pomodoro.", "pomodoro hint")
expectEqual(cmd("timer 52 17")?.hint(), "Enter to start a 52m/17m pomodoro.", "custom pomodoro hint")
expectEqual(cmd("timer 5:30 : laundry")?.hint(), "Enter to start a “laundry”: 5:30 countdown.", "named countdown hint")

// MARK: stopwatch, countdown, breathing (fake clock)
do {
    var w = NoteTimer(kind: .stopwatch, startingAt: t0)
    expectEqual(w.elapsed(at: after(75)), 75, "stopwatch counts up")
    expectEqual(w.clock(at: after(75)), "1:15", "stopwatch clock")
    expectEqual(w.tick(at: after(99_999)), false, "a stopwatch never finishes")
    w.pause(at: after(100))
    expectEqual(w.elapsed(at: after(500)), 100, "paused stopwatch stands still")
    expectEqual(w.isPaused, true, "paused")
    w.resume(at: after(500))
    expectEqual(w.elapsed(at: after(520)), 120, "resumed stopwatch continues")
    w.restart(at: after(600))
    expectEqual(w.elapsed(at: after(610)), 10, "restart goes back to zero")

    var c = NoteTimer(kind: .countdown(300), label: "tea", startingAt: t0)
    expectEqual(c.remaining(at: after(60)), 240, "countdown remaining")
    expectEqual(c.clock(at: after(60)), "4:00", "countdown clock")
    expectEqual(c.tick(at: after(299)), false, "not finished early")
    expectEqual(c.tick(at: after(300)), true, "finishes on time")
    expectEqual(c.tick(at: after(301)), false, "finishes only once")
    expectEqual(c.isFinished, true, "finished")
    expectEqual(c.remaining(at: after(1000)), 0, "nothing left")
    c.resume(at: after(1000))
    expectEqual(c.isRunning, false, "a finished timer can't be resumed")
    c.restart(at: after(2000))
    expectEqual(c.remaining(at: after(2060)), 240, "restart after finishing")
    var paused = NoteTimer(kind: .countdown(300), startingAt: t0)
    paused.pause(at: after(100))
    expectEqual(paused.tick(at: after(99_999)), false, "paused countdown never finishes")
    paused.togglePause(at: after(1000))
    expectEqual(paused.remaining(at: after(1050)), 150, "toggle resumes where it stopped")

    let b = NoteTimer(kind: .breathe(300), startingAt: t0)
    expectEqual(b.breath(at: after(0)), .inhale, "breathe starts with an inhale")
    expectEqual(b.breath(at: after(3.9)), .inhale, "still inhaling")
    expectEqual(b.breath(at: after(4)), .exhale, "then exhale")
    expectEqual(b.breath(at: after(9.9)), .exhale, "still exhaling")
    expectEqual(b.breath(at: after(10)), .inhale, "next cycle")
    expectEqual(w.breath(at: t0), nil, "only breathing has a breath")
    expectEqual(NoteTimer(.pause, startingAt: t0) == nil, true, "pause is not a timer")
    expectEqual(NoteTimer(.countdown(seconds: 60, label: "x"), startingAt: t0)?.label, "x", "timer from command")
}

// MARK: hostile input must stay fast (these took seconds to minutes before the fixes)
@MainActor func expectFast(_ label: String, seconds limit: Double = 2, _ work: () -> Void) {
    let start = Date()
    work()
    expectEqual(Date().timeIntervalSince(start) < limit, true, "fast: \(label)")
}
let wide = Locale(identifier: "de_DE")
expectFast("timer + 100k spaces") { _ = NoteCalculator.analyze("timer" + String(repeating: " ", count: 100_000) + "5", locale: wide) }
expectFast("list mode, 100k spaces") { _ = NoteCalculator.analyze("list\n" + String(repeating: " ", count: 100_000) + "x", locale: wide) }
expectFast("a a a … 100k") { _ = NoteCalculator.analyze(String(repeating: "a ", count: 50_000) + "=", locale: wide) }
expectFast("sum mode, 50k '1,'") { _ = NoteCalculator.analyze("sum\n" + String(repeating: "1,", count: 50_000), locale: wide) }
expectFast("200k-character line") { _ = NoteCalculator.analyze(String(repeating: "7 + ", count: 50_000) + "=", locale: wide) }
expectFast("timer parse, 100k spaces") { _ = TimerCommand.parse("timer" + String(repeating: " ", count: 100_000) + "5") }
expectEqual(TimerCommand.parse("timer " + String(repeating: "9", count: 500)), nil, "an overlong line is not a command")
expectEqual(NoteCalculator.analyze(String(repeating: "1 + ", count: 1_000) + "1 =", locale: us).results.count, 0, "a 4,000-character line is not calculated")

// the replacements behave like what they replaced
let named = NoteCalculator.analyze("cost  per guest : $34\nguests=5\nx1 y2: 3", locale: us)
expectEqual(named.labels.map { ($0.name.length, $0.separator.length) }.map { "\($0.0),\($0.1)" }, ["15,1", "6,1", "5,1"], "variable names with spaces")
expectEqual(NoteCalculator.analyze(" 5 = 5", locale: us).labels.count, 0, "a name can't start with a digit")
let ticked = NoteCalculator.analyze("list\na /x\nb  /X  \n/x\nc /xy\nd/x\ne", locale: us).listItems
expectEqual(ticked.map(\.isDone), [true, true, true, false, true, false], "ticked items")
expectEqual(ticked[0].doneMarker?.length, 3, "marker: space and /x")
expectEqual(ticked[1].doneMarker?.length, 6, "marker: spaces, /X and trailing spaces")
expectEqual(ticked[2].doneMarker?.length, 2, "marker: /x alone")

// MARK: notes stay private
do {
    let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    let dir = tmp.appendingPathComponent("DeskNotesChecks-\(UUID().uuidString)/Notes")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let store = NoteStore(directory: dir)
    var note = Note()
    note.text = "private"
    store.add(note)
    store.flush()
    func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1 }
    expectEqual(mode(dir), 0o700, "notes folder is owner-only")
    expectEqual(mode(dir.appendingPathComponent("\(note.id.uuidString).json")), 0o600, "note file is owner-only")
    chmod(dir.path, 0o755)  // a folder from an older version
    _ = NoteStore(directory: dir)
    expectEqual(mode(dir), 0o700, "an older, wider folder is tightened")
}

// MARK: slots, search and the All Notes list
func note(_ text: String, modified: TimeInterval = 0, slot: Int? = nil, created: TimeInterval = 0) -> Note {
    var n = Note()
    n.text = text
    n.modified = Date(timeIntervalSince1970: 1_700_000_000 + modified)
    n.created = Date(timeIntervalSince1970: 1_700_000_000 + created)
    n.slot = slot
    return n
}
expectEqual(decodeNote(#"{"slot": 3}"#)?.slot, 3, "slot kept")
expectEqual(decodeNote(#"{"slot": 0}"#)?.slot, nil, "slot 0 is not a slot")
expectEqual(decodeNote(#"{"slot": 10}"#)?.slot, nil, "slot 10 is not a slot")
expectEqual(decodeNote("{}")?.slot, nil, "no slot by default")

let oldNote = note("Gespräch Ahmet\n- Steuerberater", modified: 10)
let newNote = note("100 % impact LPs", modified: 50)
let listNote = note("list\n# Test\n- [ ] milk", modified: 30)
let everything = [oldNote, newNote, listNote]
expectEqual(NoteLibrary.visible(everything, query: "", scope: .all).map(\.text), [newNote.text, listNote.text, oldNote.text], "newest edit first")
expectEqual(NoteLibrary.visible(everything, query: "ahmet", scope: .all).count, 1, "search ignores case")
expectEqual(NoteLibrary.visible(everything, query: "gesprach", scope: .all).count, 1, "search ignores accents")
expectEqual(NoteLibrary.visible(everything, query: "steuer ahmet", scope: .all).count, 1, "every word must match")
expectEqual(NoteLibrary.visible(everything, query: "steuer milk", scope: .all).count, 0, "words must be in the same note")
expectEqual(NoteLibrary.visible(everything, query: "   ", scope: .all).count, 3, "blank search shows everything")
expectEqual(NoteLibrary.visible(everything, query: "zzz", scope: .all).count, 0, "no match")
// ties never reorder
let t1 = note("a", modified: 5, created: 1), t2 = note("b", modified: 5, created: 2)
expectEqual(NoteLibrary.visible([t1, t2], query: "", scope: .all).map(\.text), NoteLibrary.visible([t2, t1], query: "", scope: .all).map(\.text), "a tie keeps a stable order")
// slotted view
let s3 = note("three", slot: 3), s1 = note("one", slot: 1), plain = note("none")
expectEqual(NoteLibrary.visible([s3, plain, s1], query: "", scope: .slotted).map(\.text), ["one", "three"], "slots in order, others hidden")
expectEqual(NoteLibrary.visible([s3, plain, s1], query: "thr", scope: .slotted).map(\.text), ["three"], "search inside slots")
do {
    // the cached search sees edits, deletions and accents
    var index = NoteLibrary.SearchIndex()
    var edited = note("alpha", modified: 1)
    expectEqual(NoteLibrary.visible([edited], query: "beta", scope: .all, index: &index).count, 0, "cache: not there yet")
    edited.text = "alpha beta"
    edited.modified = Date(timeIntervalSince1970: 1_700_000_100)
    expectEqual(NoteLibrary.visible([edited], query: "beta", scope: .all, index: &index).count, 1, "cache: an edit is found")
    edited.text = "alpha Gamma"  // same modified time, different length: still noticed
    expectEqual(NoteLibrary.visible([edited], query: "gamma", scope: .all, index: &index).count, 1, "cache: a changed length is noticed")
    expectEqual(NoteLibrary.visible([edited], query: "GÄMMA", scope: .all, index: &index).count, 1, "cache: accents and case are ignored")
    expectEqual(NoteLibrary.visible([], query: "alpha", scope: .all, index: &index).count, 0, "cache: deleted notes are gone")
}
expectEqual(NoteLibrary.previewLines("\n\n  first  \n\nsecond\nthird\nfourth", maxLines: 3), ["first", "second", "third"], "preview skips blank lines")
expectEqual(NoteLibrary.previewLines("", maxLines: 3), [], "empty preview")
expectEqual(NoteLibrary.previewLines(String(repeating: "x", count: 1_000), maxLines: 1).first?.count, 301, "long line is cut")
expectEqual(NoteLibrary.isEmpty(note(" \n\t")), true, "blank note is empty")

do {
    let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    let dir = tmp.appendingPathComponent("DeskNotesChecks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(directory: dir)
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let token = NotificationCenter.default.addObserver(forName: NoteStore.didChange, object: store, queue: nil) { _ in counter.value += 1 }
    defer { NotificationCenter.default.removeObserver(token) }
    let a = Note(), b = Note(), c = Note()
    store.add(a); store.add(b); store.add(c)
    expectEqual(counter.value, 3, "adding notes announces a change")
    store.assignSlot(2, to: a.id)
    expectEqual(store.note(inSlot: 2)?.id, a.id, "note is in slot 2")
    store.assignSlot(2, to: b.id)
    expectEqual(store.note(inSlot: 2)?.id, b.id, "slot 2 now holds the other note")
    expectEqual(store.notes[a.id]?.slot, nil, "the first note lost its slot")
    store.assignSlot(5, to: b.id)
    expectEqual([store.note(inSlot: 2) == nil, store.note(inSlot: 5)?.id == b.id], [true, true], "moving a note frees its old slot")
    store.assignSlot(11, to: c.id)
    store.assignSlot(0, to: c.id)
    expectEqual(store.notes[c.id]?.slot, nil, "slots outside 1 to 9 are refused")
    store.assignSlot(nil, to: b.id)
    expectEqual(store.notes[b.id]?.slot, nil, "taking a note out of its slot")
    store.assignSlot(4, to: UUID())
    expectEqual(store.notes.values.contains { $0.slot == 4 }, false, "unknown note is ignored")
    let before = counter.value
    store.update(a.id, touch: false) { $0.text = "x" }
    expectEqual(counter.value, before + 1, "editing announces a change")
    store.assignSlot(7, to: a.id)
    store.flush()
    let reloaded = NoteStore(directory: dir)
    reloaded.load()
    expectEqual(reloaded.note(inSlot: 7)?.id, a.id, "a slot survives saving and loading")
}

print(failures == 0 ? "All \(total) checks passed." : "\(failures) of \(total) checks FAILED.")
exit(failures == 0 ? 0 : 1)
