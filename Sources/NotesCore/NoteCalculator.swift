import Foundation

/// A note's mode is chosen by a keyword alone on its first line (`list`, `list: Groceries`, `sum` …).
public enum NoteMode: String, Equatable, CaseIterable, Sendable {
    case plain, math, list, sum, avg, count

    /// The words that switch a note into a mode, in menu order: `math`, `list`, `sum`, `avg`, `count`.
    public static let keywords = allCases.filter { $0 != .plain }.map(\.rawValue)
}

/// One calculated line of a note.
public struct LineResult: Equatable {
    public enum Kind: Equatable {
        /// The line ends with `=`; the result is shown after it.
        case inline
        /// `name: expression` / `name = expression` defines a variable.
        case assignment
    }

    /// Range of the line's text (without the line break), in UTF-16 units.
    public let range: NSRange
    public let kind: Kind
    public let value: Double
    /// Formatted for the locale, with currency symbol: `$170,00`.
    public let display: String
    /// False for things like `x: 5`, where showing "→ 5" adds nothing.
    public let showsGhost: Bool
}

/// The name and separator of a variable definition, so the editor can colour them.
public struct VariableLabel: Equatable {
    public let name: NSRange
    public let separator: NSRange
}

/// One item of a `list` note. Ticked items end in `/x`.
public struct ListItem: Equatable {
    public let range: NSRange
    public let isDone: Bool
    /// The ` /x` at the end (with the whitespace before it) when the item is done.
    public let doneMarker: NSRange?
}

/// A summary line drawn below the note (`Total: $37,25`) – never part of the text itself.
public struct OutputLine: Equatable {
    public enum Style: Equatable { case sum, avg, count }
    public let text: String
    public let style: Style
}

public struct NoteAnalysis: Equatable {
    public var mode = NoteMode.plain
    public var keywordRange: NSRange?
    public var results: [LineResult] = []
    public var labels: [VariableLabel] = []
    public var listItems: [ListItem] = []
    public var output: [OutputLine] = []

    public init() {}
}

/// Scans a whole note top to bottom.
///
/// - `12 * 3 =` shows `36,00`.
/// - `price: 49,90` / `price * 1,19 =` – variables carry over to later lines.
/// - `sum`, `total`, `avg` inside an expression use the plain numbers above, up to the last blank line.
/// - A first line of `list`, `sum`, `avg` or `count` switches the note into that mode.
public enum NoteCalculator {
    private static let keywordRE = try! NSRegularExpression(
        pattern: #"^(\s*)("# + NoteMode.keywords.joined(separator: "|") + #")\s*(?::.*)?$"#, options: [.caseInsensitive])
    /// Quote and heading markers before a calculation (list markers are handled by `ListPrefix`).
    private static let quoteOrHeadingRE = try! NSRegularExpression(pattern: #"^\s*(?:>\s*|#{1,6}\s+)"#)
    /// `name: expression` / `name = expression`. The name is words joined by spaces and never ends in a
    /// space, so there is only one way to match it: a lazy `[… ]*?` followed by `\s*` would try every
    /// split of a long run of spaces (minutes on a line of 100,000 spaces).
    private static let labelRE = try! NSRegularExpression(
        pattern: #"^([A-Za-z_][A-Za-z0-9_]*(?: +[A-Za-z0-9_]+)*)\s*([:=])\s*(\S.*)$"#)
    /// Lines longer than this are text, not calculations; skipping them keeps a pasted wall of text cheap.
    private static let maxCalculatedLine = 2_000
    private static let literalRE = try! NSRegularExpression(pattern: #"^[$€£]?\s*[\d.,]+$"#)
    /// Numbers in `sum` / `avg` notes: `4,25` with a decimal comma, `1,250.50` with a decimal point.
    private static let commaNumberRE = try! NSRegularExpression(
        pattern: #"(?<![\w.,])([$€£])?\s?(\d+(?:[.,]\d+)?)"#)
    private static let pointNumberRE = try! NSRegularExpression(
        pattern: #"(?<![\w.,])([$€£])?\s?(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)"#)

    public static func analyze(_ text: String, locale: Locale = .current) -> NoteAnalysis {
        var analysis = NoteAnalysis()
        let ns = text as NSString
        guard ns.length > 0 else { return analysis }

        var lines: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            lines.append(range)
        }
        guard let first = lines.first else { return analysis }

        let firstText = ns.substring(with: first)
        if let m = keywordRE.firstMatch(in: firstText, range: NSRange(location: 0, length: (firstText as NSString).length)) {
            let word = (firstText as NSString).substring(with: m.range(at: 2)).lowercased()
            analysis.mode = NoteMode(rawValue: word) ?? .plain
            analysis.keywordRange = NSRange(location: first.location + m.range(at: 2).location, length: m.range(at: 2).length)
        }

        let body = analysis.mode == .plain ? lines : Array(lines.dropFirst())
        let decimalComma = locale.decimalSeparator == ","

        switch analysis.mode {
        case .plain, .math:
            calculate(body, ns, decimalComma, locale, &analysis)
        case .list:
            listItems(body, ns, &analysis)
        case .sum, .avg:
            totals(body, ns, decimalComma, locale, &analysis)
        case .count:
            statistics(body, ns, locale, &analysis)
        }
        return analysis
    }

    // MARK: Calculation (plain and math notes)

    private static func calculate(_ lines: [NSRange], _ ns: NSString, _ decimalComma: Bool,
                                  _ locale: Locale, _ analysis: inout NoteAnalysis) {
        var calc = Calculator(decimalComma: decimalComma)
        var userVariables = Set<String>()
        var block: [Double] = []

        for lineRange in lines {
            let raw = ns.substring(with: lineRange)
            let rawNS = raw as NSString
            var prefixLength = 0
            if let list = ListPrefix.match(in: raw) {
                prefixLength = list.range.length
            } else if let m = quoteOrHeadingRE.firstMatch(in: raw, range: NSRange(location: 0, length: rawNS.length)) {
                prefixLength = m.range.length
            }
            let afterPrefix = rawNS.substring(from: prefixLength) as NSString
            var leading = 0
            while leading < afterPrefix.length,
                  let scalar = UnicodeScalar(afterPrefix.character(at: leading)),
                  CharacterSet.whitespaces.contains(scalar) {
                leading += 1
            }
            var body = afterPrefix.substring(from: leading).trimmingCharacters(in: .whitespaces)
            if body.isEmpty {
                block.removeAll()
                continue
            }
            if (body as NSString).length > maxCalculatedLine { continue }
            let bodyOffset = lineRange.location + prefixLength + leading

            var trailingEquals = false
            if body.hasSuffix("=") {
                trailingEquals = true
                body.removeLast()
                body = body.trimmingCharacters(in: .whitespaces)
            }

            // Block statistics as variables, unless the user defined the same name.
            let sum = block.reduce(0, +)
            for (name, value) in [("sum", sum), ("total", sum), ("avg", block.isEmpty ? 0 : sum / Double(block.count))]
            where !userVariables.contains(name) {
                calc.variables[name] = value
            }

            let bodyNS = body as NSString
            if let m = labelRE.firstMatch(in: body, range: NSRange(location: 0, length: bodyNS.length)) {
                let nameText = bodyNS.substring(with: m.range(at: 1))
                let expression = bodyNS.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
                guard let (value, currency) = try? calc.evaluateFull(expression) else { continue }

                let key = nameText.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                calc.variables[key] = value
                calc.currencies[key] = currency
                userVariables.insert(key)
                block.append(value)

                analysis.labels.append(VariableLabel(
                    name: NSRange(location: bodyOffset + m.range(at: 1).location, length: m.range(at: 1).length),
                    separator: NSRange(location: bodyOffset + m.range(at: 2).location, length: 1)))

                let display = Calculator.format(value, currency: currency, locale: locale)
                if trailingEquals {
                    analysis.results.append(LineResult(range: lineRange, kind: .inline, value: value,
                                                       display: display, showsGhost: true))
                } else {
                    let trivial = literalRE.firstMatch(in: expression, range: NSRange(location: 0, length: (expression as NSString).length)) != nil
                    analysis.results.append(LineResult(range: lineRange, kind: .assignment, value: value,
                                                       display: display, showsGhost: !trivial))
                }
                continue
            }

            guard let (value, currency) = try? calc.evaluateFull(body) else { continue }
            block.append(value)
            if trailingEquals {
                analysis.results.append(LineResult(range: lineRange, kind: .inline, value: value,
                                                   display: Calculator.format(value, currency: currency, locale: locale),
                                                   showsGhost: true))
            }
        }
    }

    // MARK: list

    private static func listItems(_ lines: [NSRange], _ ns: NSString, _ analysis: inout NoteAnalysis) {
        for range in lines where range.length > 0 {
            let text = ns.substring(with: range)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            var marker: NSRange?
            if let m = doneMarker(in: text as NSString) {
                marker = NSRange(location: range.location + m.location, length: m.length)
            }
            analysis.listItems.append(ListItem(range: range, isDone: marker != nil, doneMarker: marker))
        }
    }

    /// The ` /x` at the end of a ticked item, with the whitespace before it (and any after it).
    /// Scans backwards from the end instead of using a regular expression: `(\s*)/x\s*$` is quadratic
    /// on a long run of spaces, because it is tried from every position.
    private static func doneMarker(in text: NSString) -> NSRange? {
        func isSpace(_ unit: unichar) -> Bool {
            UnicodeScalar(unit).map { CharacterSet.whitespaces.contains($0) } ?? false
        }
        var end = text.length
        while end > 0, isSpace(text.character(at: end - 1)) { end -= 1 }
        guard end >= 2, text.character(at: end - 2) == 0x2F /* / */,
              text.character(at: end - 1) == 0x78 || text.character(at: end - 1) == 0x58 /* x X */ else { return nil }
        var start = end - 2
        while start > 0, isSpace(text.character(at: start - 1)) { start -= 1 }
        return NSRange(location: start, length: text.length - start)
    }

    // MARK: sum / avg

    private static func totals(_ lines: [NSRange], _ ns: NSString, _ decimalComma: Bool,
                               _ locale: Locale, _ analysis: inout NoteAnalysis) {
        let regex = decimalComma ? commaNumberRE : pointNumberRE

        var values: [Double] = []
        var currency: Character?
        for range in lines {
            let text = ns.substring(with: range) as NSString
            regex.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, _ in
                guard let m = match else { return }
                var number = text.substring(with: m.range(at: 2))
                number = decimalComma ? number.replacingOccurrences(of: ",", with: ".") : number.replacingOccurrences(of: ",", with: "")
                guard let value = Double(number) else { return }
                values.append(value)
                if currency == nil, m.range(at: 1).location != NSNotFound {
                    currency = text.substring(with: m.range(at: 1)).first
                }
            }
        }
        guard !values.isEmpty else { return }
        let total = values.reduce(0, +)
        if analysis.mode == .sum {
            analysis.output = [OutputLine(text: "Total: " + Calculator.format(total, currency: currency, locale: locale), style: .sum)]
        } else {
            analysis.output = [OutputLine(text: "Avg: " + Calculator.format(total / Double(values.count), currency: currency, locale: locale), style: .avg)]
        }
    }

    // MARK: count

    private static func statistics(_ lines: [NSRange], _ ns: NSString, _ locale: Locale, _ analysis: inout NoteAnalysis) {
        guard let firstLine = lines.first, let lastLine = lines.last else { return }
        let whole = NSRange(location: firstLine.location, length: NSMaxRange(lastLine) - firstLine.location)
        let body = ns.substring(with: whole).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        let items = lines.filter { !ns.substring(with: $0).trimmingCharacters(in: .whitespaces).isEmpty }.count
        let words = body.split(whereSeparator: { $0.isWhitespace })
        let sentences = max(1, body.split(whereSeparator: { ".!?\n".contains($0) })
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count)
        let syllables = words.reduce(0) { $0 + syllableCount(String($1)) }

        let formatter = Calculator.cachedFormatter(locale: locale, style: .none, fractionDigits: 2...2)
        func number(_ value: Double) -> String {
            formatter.string(from: NSNumber(value: value)) ?? String(value)
        }

        let wordsPerSentence = Double(words.count) / Double(sentences)
        let syllablesPerWord = Double(syllables) / Double(max(words.count, 1))
        let reading = 206.835 - 1.015 * wordsPerSentence - 84.6 * syllablesPerWord
        let grade = 0.39 * wordsPerSentence + 11.8 * syllablesPerWord - 15.59

        analysis.output = [
            OutputLine(text: "Items: \(items)", style: .count),
            OutputLine(text: "Words: \(words.count)", style: .count),
            OutputLine(text: "Characters: \(body.count)", style: .count),
            OutputLine(text: "Sentences: \(sentences)", style: .count),
            OutputLine(text: "Flesch Reading Ease Score: \(number(reading))", style: .count),
            OutputLine(text: "Flesch\u{2013}Kincaid Grade Level: \(number(grade))", style: .count),
        ]
    }

    /// Rough English syllable estimate: groups of vowels, minus a silent final "e".
    private static func syllableCount(_ word: String) -> Int {
        let letters = word.lowercased().filter { $0.isLetter }
        guard !letters.isEmpty else { return 0 }
        var count = 0
        var previousWasVowel = false
        for ch in letters {
            let isVowel = "aeiouy".contains(ch)
            if isVowel && !previousWasVowel { count += 1 }
            previousWasVowel = isVowel
        }
        if letters.hasSuffix("e"), !letters.hasSuffix("le"), count > 1 { count -= 1 }
        return max(count, 1)
    }
}
