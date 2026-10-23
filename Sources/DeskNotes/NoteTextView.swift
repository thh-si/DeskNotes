import AppKit
import NotesCore

/// The editor. On top of NSTextView it adds:
/// - green calculator results after lines ending in `=` (Tab or Return writes them into the note),
/// - drawn checkboxes for `list` notes (click to tick; ticking appends ` /x`),
/// - the `Total: …` / `Words: …` summary block under `sum`, `avg` and `count` notes,
/// - Markdown conveniences: list continuation, clickable checkboxes, ⌘-click links, ⌘B / ⌘I …
final class NoteTextView: NSTextView {
    var theme = NoteTheme.fallback {
        didSet {
            insertionPointColor = theme.cursor
            needsDisplay = true
        }
    }
    var baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    var placeholder = "Start typing…   or begin with   math · list · sum · avg · count"

    /// Set by the styler after every edit.
    var analysis = NoteAnalysis() {
        didSet {
            guard analysis != oldValue else { return }
            scheduleInsetUpdate()
            needsDisplay = true
        }
    }

    // MARK: Layout

    private let topPadding: CGFloat = 32       // room under the (invisible) title bar
    let sidePadding: CGFloat = 46
    private let bottomPadding: CGFloat = 80    // room for the hover toolbar

    /// Lines (by start offset) whose result didn't fit and is drawn on its own line; set by the styler.
    var overflowingResults = Set<Int>() {
        didSet { needsDisplay = true }
    }
    private var insetUpdateScheduled = false

    /// Height of one text line, including line-height multiple and paragraph spacing.
    private var lineAdvance: CGFloat {
        (layoutManager?.defaultLineHeight(for: baseFont) ?? 17) * Metrics.lineHeightMultiple + Metrics.paragraphSpacing
    }

    /// The text is placed `topPadding` from the top, while the view reserves the *sum* of top, bottom
    /// and summary-block space (NSTextView's inset is symmetric, so we split it by overriding the origin).
    override var textContainerOrigin: NSPoint { NSPoint(x: sidePadding, y: topPadding) }

    func updateInsets() {
        let reserve = analysis.output.isEmpty ? 0 : CGFloat(analysis.output.count) * lineAdvance + 18
        let height = (topPadding + bottomPadding + reserve) / 2
        if textContainerInset.height != height || textContainerInset.width != sidePadding {
            textContainerInset = NSSize(width: sidePadding, height: height)
        }
    }

    private func scheduleInsetUpdate() {
        guard !insetUpdateScheduled else { return }
        insetUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.insetUpdateScheduled = false
            self?.updateInsets()
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin

        if string.isEmpty {
            placeholder.draw(at: NSPoint(x: origin.x, y: origin.y),
                             withAttributes: [.font: baseFont, .foregroundColor: theme.marker])
            return
        }
        let length = (string as NSString).length

        // Only lay out and measure what is being redrawn, not the whole note. Two extra lines on each
        // side catch results drawn on the line below their own (see `overflowingResults`).
        let margin = 2 * lineAdvance
        let dirtyInContainer = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -margin)
        let visibleGlyphs = lm.glyphRange(forBoundingRect: dirtyInContainer, in: tc)
        let visible = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        func isVisible(_ range: NSRange) -> Bool {
            range.location >= visible.location && range.location <= NSMaxRange(visible)
        }

        // Checkboxes of `list` notes
        for item in analysis.listItems where isVisible(item.range) {
            guard let rect = boxRect(for: item, lm, origin) else { continue }
            drawBox(in: rect, done: item.isDone)
        }

        // Calculator results: green, right after the "="
        let ghostAttributes: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: theme.resultColor]
        for result in analysis.results where result.showsGhost && isVisible(result.range) {
            guard result.range.length > 0, NSMaxRange(result.range) <= length else { continue }
            let lastChar = NSRange(location: NSMaxRange(result.range) - 1, length: 1)
            let glyphs = lm.glyphRange(forCharacterRange: lastChar, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let baseline = fragment.minY + lm.location(forGlyphAt: glyphs.location).y

            if overflowingResults.contains(result.range.location) {
                // Doesn't fit after the "=": show it on the line below (the styler left room for it).
                let step = lm.defaultLineHeight(for: baseFont) * Metrics.lineHeightMultiple
                result.display.draw(at: NSPoint(x: origin.x, y: origin.y + baseline + step - baseFont.ascender),
                                    withAttributes: ghostAttributes)
                continue
            }
            let label = (result.kind == .inline ? " " : "  → ") + result.display
            let width = (label as NSString).size(withAttributes: ghostAttributes).width
            var x = rect.maxX + origin.x
            let limit = origin.x + tc.size.width
            if x + width > limit { x = max(origin.x, limit - width) }
            label.draw(at: NSPoint(x: x, y: origin.y + baseline - baseFont.ascender), withAttributes: ghostAttributes)
        }

        // Summary block under sum / avg / count notes
        if !analysis.output.isEmpty {
            // The block sits below all the text, so its position needs the complete layout.
            lm.ensureLayout(for: tc)
            let used = max(lm.usedRect(for: tc).maxY, lm.extraLineFragmentRect.maxY)
            var y = origin.y + used + 18
            for line in analysis.output {
                line.text.draw(at: NSPoint(x: origin.x, y: y),
                               withAttributes: [.font: baseFont, .foregroundColor: theme.outputColor(line.style)])
                y += lineAdvance
            }
        }
    }

    private func boxRect(for item: ListItem, _ lm: NSLayoutManager, _ origin: NSPoint) -> NSRect? {
        guard item.range.length > 0, NSMaxRange(item.range) <= (string as NSString).length else { return nil }
        let glyph = lm.glyphIndexForCharacter(at: item.range.location)
        let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = fragment.minY + lm.location(forGlyphAt: glyph).y
        let size: CGFloat = 16
        let centerY = origin.y + baseline - baseFont.capHeight / 2
        return NSRect(x: origin.x + 1, y: centerY - size / 2, width: size, height: size)
    }

    private func drawBox(in rect: NSRect, done: Bool) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.7, dy: 0.7), xRadius: 4.5, yRadius: 4.5)
        path.lineWidth = 1.4
        if done {
            let purple = theme.purple.withAlphaComponent(0.55)
            purple.setStroke()
            path.stroke()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + 4.3, y: rect.minY + 8.3))
            check.line(to: NSPoint(x: rect.minX + 7, y: rect.minY + 11))
            check.line(to: NSPoint(x: rect.minX + 11.8, y: rect.minY + 5))
            check.lineWidth = 1.5
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        } else {
            theme.text.withAlphaComponent(0.85).setStroke()
            path.stroke()
        }
    }

    // MARK: Calculator

    /// If the caret sits at the end of a line that has a result, writes the result into the note.
    @discardableResult
    private func commitResultAtCaret() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 0 else { return false }
        guard let result = analysis.results.first(where: { $0.kind == .inline && NSMaxRange($0.range) == selection.location }) else {
            return false
        }
        let previous = (string as NSString).substring(with: NSRange(location: selection.location - 1, length: 1))
        insertText((previous == " " ? "" : " ") + result.display,
                   replacementRange: NSRange(location: selection.location, length: 0))
        return true
    }

    override func insertTab(_ sender: Any?) {
        if commitResultAtCaret() { return }
        super.insertTab(sender)
    }

    // MARK: Lists

    private static let listRE = try! NSRegularExpression(
        pattern: #"^(\s*)(?:([-*+])|(\d+)([.)]))(\s+)(\[[ xX]\]\s+)?"#)

    override func insertNewline(_ sender: Any?) {
        commitResultAtCaret()
        if continueList() { return }
        super.insertNewline(sender)
    }

    /// Enter at the end of a Markdown list item starts the next item; Enter on an empty item ends the list.
    private func continueList() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, analysis.mode != .list else { return false }
        let ns = string as NSString
        var start = 0, end = 0, contentsEnd = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: selection)
        guard selection.location == contentsEnd else { return false }

        let line = NSRange(location: start, length: contentsEnd - start)
        let text = ns.substring(with: line) as NSString
        guard let m = Self.listRE.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else {
            return false
        }

        if m.range.length == line.length {
            if shouldChangeText(in: line, replacementString: "") {
                textStorage?.replaceCharacters(in: line, with: "")
                didChangeText()
            }
            return true
        }

        let indent = text.substring(with: m.range(at: 1))
        let marker: String
        if m.range(at: 2).location != NSNotFound {
            marker = text.substring(with: m.range(at: 2))
        } else {
            let number = Int(text.substring(with: m.range(at: 3))) ?? 0
            marker = "\(number + 1)" + text.substring(with: m.range(at: 4))
        }
        let spacing = text.substring(with: m.range(at: 5))
        let box = m.range(at: 6).location != NSNotFound ? "[ ] " : ""

        super.insertNewline(nil)
        insertText(indent + marker + spacing + box, replacementRange: selectedRange())
        return true
    }

    // MARK: Mouse: checkboxes and links

    private static let checkboxRE = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+(\[[ xX]\])"#)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let lm = layoutManager {
            let origin = textContainerOrigin
            for item in analysis.listItems {
                if let rect = boxRect(for: item, lm, origin), rect.insetBy(dx: -6, dy: -6).contains(point) {
                    toggleDone(item)
                    return
                }
            }
        }
        if let box = markdownCheckboxHit(at: point) {
            let middle = NSRange(location: box.location + 1, length: 1)
            let current = (string as NSString).substring(with: middle)
            replace(middle, with: current == " " ? "x" : " ")
            return
        }
        if event.modifierFlags.contains(.command),
           let index = characterIndexHit(at: point),
           let target = textStorage?.attribute(.deskLink, at: index, effectiveRange: nil) as? String {
            if let url = LinkPolicy.url(for: target) {
                NSWorkspace.shared.open(url)
            } else {
                NSSound.beep()
            }
            return
        }
        super.mouseDown(with: event)
    }

    private func replace(_ range: NSRange, with text: String) {
        if shouldChangeText(in: range, replacementString: text) {
            textStorage?.replaceCharacters(in: range, with: text)
            didChangeText()
        }
    }

    /// Ticks or unticks a `list` item by adding / removing a trailing ` /x`.
    private func toggleDone(_ item: ListItem) {
        if let marker = item.doneMarker {
            replace(marker, with: "")
        } else {
            replace(NSRange(location: NSMaxRange(item.range), length: 0), with: " /x")
        }
    }

    /// The character under the point, or nil when the point is past the end of a line.
    private func characterIndexHit(at point: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, !string.isEmpty else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = lm.glyphIndex(for: local, in: tc)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard rect.contains(local) else { return nil }
        return lm.characterIndexForGlyph(at: glyph)
    }

    private func markdownCheckboxHit(at point: NSPoint) -> NSRange? {
        guard let lm = layoutManager, let tc = textContainer, !string.isEmpty else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = lm.glyphIndex(for: local, in: tc)
        let index = lm.characterIndexForGlyph(at: glyph)

        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
        let line = ns.substring(with: lineRange)
        guard let m = Self.checkboxRE.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return nil
        }
        let box = NSRange(location: lineRange.location + m.range(at: 1).location, length: 3)
        let glyphs = lm.glyphRange(forCharacterRange: box, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc).insetBy(dx: -3, dy: -2)
        return rect.contains(local) ? box : nil
    }

    // MARK: Formatting commands (Format menu)

    /// Wraps the selection in `open`/`close`; wrapping an already wrapped selection removes the markers.
    private func wrapSelection(_ open: String, _ close: String) {
        let selection = selectedRange()
        let ns = string as NSString
        let openLen = open.utf16.count, closeLen = close.utf16.count

        if selection.location >= openLen, NSMaxRange(selection) + closeLen <= ns.length,
           ns.substring(with: NSRange(location: selection.location - openLen, length: openLen)) == open,
           ns.substring(with: NSRange(location: NSMaxRange(selection), length: closeLen)) == close {
            let outer = NSRange(location: selection.location - openLen, length: selection.length + openLen + closeLen)
            insertText(ns.substring(with: selection), replacementRange: outer)
            setSelectedRange(NSRange(location: outer.location, length: selection.length))
            return
        }

        insertText(open + ns.substring(with: selection) + close, replacementRange: selection)
        if selection.length == 0 {
            setSelectedRange(NSRange(location: selection.location + openLen, length: 0))
        } else {
            setSelectedRange(NSRange(location: selection.location + openLen, length: selection.length))
        }
    }

    @objc func toggleBold(_ sender: Any?) { wrapSelection("**", "**") }
    @objc func toggleItalic(_ sender: Any?) { wrapSelection("*", "*") }
    @objc func toggleStrikethrough(_ sender: Any?) { wrapSelection("~~", "~~") }
    @objc func toggleHighlight(_ sender: Any?) { wrapSelection("==", "==") }
    @objc func toggleCode(_ sender: Any?) { wrapSelection("`", "`") }

    @objc func applyTextColor(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        wrapSelection("{\(name)|", "}")
    }
}
