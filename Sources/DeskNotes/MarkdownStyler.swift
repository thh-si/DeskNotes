import AppKit
import NotesCore

extension NSAttributedString.Key {
    /// Marks the text of a `[label](url)` link; ⌘-click opens it.
    static let deskLink = NSAttributedString.Key("DeskNotesLink")
    /// Marks text the spell checker should leave alone (keywords, variable names, code, link targets).
    static let deskNoSpell = NSAttributedString.Key("DeskNotesNoSpell")
}

enum Metrics {
    /// Every text line is ~22 pt apart, whether it is a new line or a wrapped one (as in the reference).
    static let lineHeightMultiple: CGFloat = 1.32
    static let paragraphSpacing: CGFloat = 0
    /// Extra air between `list` items and `count` lines.
    static let itemSpacing: CGFloat = 6
    /// Space reserved to the left of list items for the drawn checkbox.
    static let listIndent: CGFloat = 28
}

/// Live styling. The note's text stays plain; this only layers fonts, colours and paragraph
/// attributes on top of it, every time the text changes:
///
/// - the first-line keyword (`list`, `math`, `sum`, `avg`, `count`) in its colour,
/// - `# headings` in navy / teal / purple, `name: value` variables, ticked `list` items,
/// - Markdown: `**bold**`, `*italic*`, `~~strike~~`, `==highlight==`, `` `code` ``, fenced code,
///   `> quotes`, `- bullets`, `1. numbers`, `- [ ] checkboxes`, `---`, `[links](https://…)`,
/// - coloured text: `{red|text}`, `{#FF8800|text}`.
/// The note's text storage is only edited on the main thread (`@preconcurrency` checks that at run time).
@MainActor
final class MarkdownStyler: NSObject, @preconcurrency NSTextStorageDelegate {
    var theme: NoteTheme
    var fontSize: CGFloat
    weak var textView: NoteTextView?
    private(set) var analysis = NoteAnalysis()

    var baseFont: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    private var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize * 0.94, weight: .regular) }

    init(theme: NoteTheme, fontSize: CGFloat) {
        self.theme = theme
        self.fontSize = fontSize
    }

    // MARK: NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Don't disturb input-method composition (dead keys, Japanese, …); the commit re-triggers this.
        if textView?.hasMarkedText() == true { return }
        style(textStorage)
    }

    /// Longest line that gets bold / italic / code / link styling.
    static let maxInlineLine = 1_500

    // MARK: Regular expressions

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static let headingRE = regex(#"^(#{1,6})(\s+)"#)
    private static let quoteRE = regex(#"^(\s*>)\s?"#)
    private static let ruleRE = regex(#"^\s*(?:-{3,}|\*{3,}|_{3,})\s*$"#)

    private static let codeRE = regex(#"`([^`\n]+)`"#)
    private static let colorRE = regex(#"\{([#A-Za-z0-9]+)\|([^}\n]+)\}"#)
    private static let linkRE = regex(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    private static let highlightRE = regex(#"==(?=\S)(.+?)(?<=\S)=="#)
    private static let strikeRE = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let boldStarRE = regex(#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#)
    private static let boldUnderRE = regex(#"__(?=\S)(.+?)(?<=\S)__"#)
    private static let italicStarRE = regex(#"(?<![\*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\*\w])"#)
    private static let italicUnderRE = regex(#"(?<![_\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#)

    // MARK: Styling

    /// Re-applies all attributes to the whole note. Notes are small, so this is cheap.
    func style(_ storage: NSTextStorage) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        analysis = NoteCalculator.analyze(storage.string)
        textView?.analysis = analysis
        guard full.length > 0 else { return }

        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: theme.text,
            .paragraphStyle: paragraphStyle(indent: 0),
        ], range: full)

        var inFence = false
        ns.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let text = ns.substring(with: line)
            if text.hasPrefix("```") {
                inFence.toggle()
                self.styleCodeBlockLine(storage, line)
                storage.addAttribute(.foregroundColor, value: self.theme.marker, range: line)
                return
            }
            if inFence {
                self.styleCodeBlockLine(storage, line)
                return
            }
            if TimerCommand.parse(text) != nil {
                storage.addAttributes([.foregroundColor: self.theme.timerColor, .deskNoSpell: true], range: line)
            }
            self.styleBlock(storage, text, line)
            // The inline patterns are quadratic on some long lines (8 s on 20,000 characters of
            // "*a *a …"), and they run on every keystroke: past this length a line stays plain.
            if line.length <= Self.maxInlineLine { self.styleInline(storage, ns as String, line) }
        }

        styleAnalysis(storage, ns)
        styleOverflowingResults(storage, ns)
    }

    /// A result that doesn't fit after its line moves to a line of its own, like in the reference.
    /// We can't know the real wrapping before layout, so this estimates it from the font's width;
    /// the window re-styles on resize. The extra line is made by a bit of paragraph spacing.
    private func styleOverflowingResults(_ s: NSTextStorage, _ ns: NSString) {
        var overflowing = Set<Int>()
        defer {
            if textView?.overflowingResults != overflowing { textView?.overflowingResults = overflowing }
        }
        guard let tv = textView else { return }
        let available = tv.bounds.width - 2 * tv.sidePadding
        guard available > 40 else { return }

        let attributes: [NSAttributedString.Key: Any] = [.font: baseFont]
        let lineStep = (tv.layoutManager?.defaultLineHeight(for: baseFont) ?? 17) * Metrics.lineHeightMultiple
        for result in analysis.results where result.showsGhost && NSMaxRange(result.range) <= ns.length {
            let lineWidth = (ns.substring(with: result.range) as NSString).size(withAttributes: attributes).width
            let ghost = (result.kind == .inline ? " " : "  → ") + result.display
            let ghostWidth = (ghost as NSString).size(withAttributes: attributes).width
            let fragments = max(1, (lineWidth / available).rounded(.up))
            let lastFragment = lineWidth - (fragments - 1) * available
            guard lastFragment + ghostWidth > available else { continue }

            overflowing.insert(result.range.location)
            let paragraph = ns.paragraphRange(for: result.range)
            let current = (s.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)
                ?? paragraphStyle(indent: 0)
            let style = current.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing += lineStep
            s.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
    }

    /// What typing in an empty note looks like. An empty note has no text to take its look from, so the
    /// caret would otherwise use the default font and line height and sit off from the placeholder.
    var baseTypingAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: theme.text, .paragraphStyle: paragraphStyle(indent: 0)]
    }

    private func paragraphStyle(indent: CGFloat, firstLine: CGFloat? = nil,
                                spacing: CGFloat = Metrics.paragraphSpacing) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = Metrics.lineHeightMultiple
        p.paragraphSpacing = spacing
        p.firstLineHeadIndent = firstLine ?? indent
        p.headIndent = indent
        return p
    }

    private func styleCodeBlockLine(_ s: NSTextStorage, _ line: NSRange) {
        s.addAttributes([.font: monoFont, .backgroundColor: theme.codeBackground, .deskNoSpell: true], range: line)
    }

    /// Everything the calculator / mode analysis knows: keyword, variable names, list items.
    private func styleAnalysis(_ s: NSTextStorage, _ ns: NSString) {
        if let range = analysis.keywordRange, let color = theme.keywordColor(analysis.mode), NSMaxRange(range) <= ns.length {
            s.addAttributes([.foregroundColor: color, .deskNoSpell: true], range: range)
        }
        for label in analysis.labels where NSMaxRange(label.separator) <= ns.length {
            s.addAttribute(.deskNoSpell, value: true, range: label.name)
            s.addAttribute(.foregroundColor, value: theme.teal, range: label.name)
            s.addAttribute(.foregroundColor, value: theme.purple, range: label.separator)
        }
        if analysis.mode == .count {
            s.addAttribute(.paragraphStyle, value: paragraphStyle(indent: 0, spacing: Metrics.itemSpacing),
                           range: NSRange(location: 0, length: ns.length))
        }
        for item in analysis.listItems where NSMaxRange(item.range) <= ns.length {
            let paragraph = ns.paragraphRange(for: item.range)
            let indent = Metrics.listIndent
            s.addAttribute(.paragraphStyle, value: paragraphStyle(indent: indent, spacing: Metrics.itemSpacing), range: paragraph)
            guard item.isDone else { continue }
            let textEnd = item.doneMarker?.location ?? NSMaxRange(item.range)
            let textRange = NSRange(location: item.range.location, length: max(0, textEnd - item.range.location))
            s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                             .foregroundColor: theme.text.withAlphaComponent(0.35)], range: textRange)
            if let marker = item.doneMarker {
                s.addAttribute(.foregroundColor, value: theme.text.withAlphaComponent(0.22), range: marker)
            }
        }
    }

    private func styleBlock(_ s: NSTextStorage, _ text: String, _ line: NSRange) {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        func abs(_ r: NSRange) -> NSRange { NSRange(location: line.location + r.location, length: r.length) }

        if let m = Self.headingRE.firstMatch(in: text, range: whole) {
            // Same size as body text, like the reference: colour by level, `#` stays visible.
            // Levels 1 and 2 are bold; level 3 and deeper are regular weight.
            let level = m.range(at: 1).length
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: level <= 2 ? .bold : .regular)
            s.addAttributes([.font: font, .foregroundColor: theme.headingColor(level: level)], range: line)
            return
        }
        if Self.ruleRE.firstMatch(in: text, range: whole) != nil {
            s.addAttribute(.foregroundColor, value: theme.marker, range: line)
            return
        }
        if let m = Self.quoteRE.firstMatch(in: text, range: whole) {
            s.addAttribute(.foregroundColor, value: theme.secondary, range: line)
            addTrait(s, .italic, line)
            s.addAttribute(.foregroundColor, value: theme.purple, range: abs(m.range(at: 1)))
            return
        }
        if let prefix = ListPrefix.match(in: text) {
            let width = ((text as NSString).substring(with: prefix.range) as NSString).size(withAttributes: [.font: baseFont]).width
            s.addAttribute(.paragraphStyle, value: paragraphStyle(indent: width, firstLine: 0), range: line)
            s.addAttribute(.foregroundColor, value: theme.purple, range: abs(prefix.marker))
            if let box = prefix.box {
                s.addAttribute(.foregroundColor, value: theme.purple, range: abs(box))
                if prefix.isChecked {
                    let end = NSMaxRange(abs(prefix.range))
                    s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                     .foregroundColor: theme.secondary],
                                    range: NSRange(location: end, length: NSMaxRange(line) - end))
                }
            }
        }
    }

    private func styleInline(_ s: NSTextStorage, _ string: String, _ line: NSRange) {
        var protected: [NSRange] = []

        func each(_ re: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            // A plain loop, not enumerateMatches with a closure: the compiler on GitHub's build machines
            // rejects handing `body` to that closure as a data race.
            for m in re.matches(in: string, options: [], range: line) {
                let matched = m.range  // an NSRange is a plain value; the closure then captures no non-Sendable object
                if protected.contains(where: { NSIntersectionRange($0, matched).length > 0 }) { continue }
                body(m)
            }
        }
        func dim(_ r: NSRange) {
            guard r.length > 0 else { return }
            s.addAttribute(.foregroundColor, value: theme.marker, range: r)
        }
        /// Dims the delimiters around capture group 1 (everything in the match outside the group).
        func dimDelimiters(_ m: NSTextCheckingResult) {
            let inner = m.range(at: 1)
            dim(NSRange(location: m.range.location, length: inner.location - m.range.location))
            dim(NSRange(location: NSMaxRange(inner), length: NSMaxRange(m.range) - NSMaxRange(inner)))
        }

        each(Self.codeRE) { m in
            s.addAttributes([.font: monoFont, .backgroundColor: theme.codeBackground, .deskNoSpell: true], range: m.range)
            dim(NSRange(location: m.range.location, length: 1))
            dim(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
            protected.append(m.range)
        }
        // Colour first, so that the dimming of other markers inside the span wins over it.
        each(Self.colorRE) { m in
            let name = (string as NSString).substring(with: m.range(at: 1))
            guard let color = theme.color(named: name) else { return }
            let inner = m.range(at: 2)
            s.addAttribute(.foregroundColor, value: color, range: inner)
            dim(NSRange(location: m.range.location, length: inner.location - m.range.location))
            dim(NSRange(location: NSMaxRange(inner), length: NSMaxRange(m.range) - NSMaxRange(inner)))
        }
        each(Self.linkRE) { m in
            let label = m.range(at: 1)
            let target = (string as NSString).substring(with: m.range(at: 2))
            s.addAttributes([.foregroundColor: theme.accent,
                             .underlineStyle: NSUnderlineStyle.single.rawValue,
                             .deskLink: target,
                             // The label can say anything; hovering shows where the link really goes.
                             .toolTip: target], range: label)
            dim(NSRange(location: m.range.location, length: 1))
            dim(NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label)))
            s.addAttribute(.deskNoSpell, value: true, range: m.range(at: 2))
        }
        each(Self.highlightRE) { m in
            s.addAttribute(.backgroundColor, value: theme.highlight, range: m.range(at: 1))
            dimDelimiters(m)
        }
        each(Self.strikeRE) { m in
            s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            dimDelimiters(m)
        }
        for re in [Self.boldStarRE, Self.boldUnderRE] {
            each(re) { m in
                addTrait(s, .bold, m.range(at: 1))
                dimDelimiters(m)
            }
        }
        for re in [Self.italicStarRE, Self.italicUnderRE] {
            each(re) { m in
                addTrait(s, .italic, m.range(at: 1))
                dimDelimiters(m)
            }
        }
    }

    /// Adds bold/italic on top of whatever font each run already has.
    private func addTrait(_ s: NSTextStorage, _ trait: NSFontDescriptor.SymbolicTraits, _ range: NSRange) {
        var runs: [(NSRange, NSFont)] = []
        s.enumerateAttribute(.font, in: range, options: []) { value, r, _ in
            if let font = value as? NSFont { runs.append((r, font)) }
        }
        for (r, font) in runs {
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
            s.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font, range: r)
        }
    }
}
