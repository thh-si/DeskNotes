import Foundation
import NotesCore

var failures = 0
var total = 0

let us = Locale(identifier: "en_US")
let de = Locale(identifier: "de_DE")

func expectValue(_ expression: String, _ expected: Double, tolerance: Double = 1e-9) {
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

func expectError(_ expression: String) {
    total += 1
    if let got = try? Calculator().evaluate(expression) {
        failures += 1
        print("FAIL  \(expression) = \(got), expected an error")
    }
}

func expectEqual<T: Equatable>(_ got: T, _ expected: T, _ label: String) {
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

print(failures == 0 ? "All \(total) checks passed." : "\(failures) of \(total) checks FAILED.")
exit(failures == 0 ? 0 : 1)
