import AppKit
import NotesCore

private func rgb(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// A note colour scheme. Backgrounds are fixed (like paper), so text colours are fixed too,
/// independent of the system's light/dark mode. "Paper" is the default white card.
struct NoteTheme {
    let id: String
    let name: String
    let background: NSColor
    let isDark: Bool

    private func pick(_ light: Int, _ dark: Int) -> NSColor { rgb(isDark ? dark : light) }

    // MARK: Base colours

    var text: NSColor { isDark ? rgb(0xEDEDED) : rgb(0x3F3A36) }
    /// Markdown syntax characters (`**`, `{red|` …) are dimmed to this.
    var marker: NSColor { text.withAlphaComponent(0.35) }
    var secondary: NSColor { text.withAlphaComponent(0.62) }
    var accent: NSColor { pick(0x0A5FD6, 0x6CB2FF) }
    var codeBackground: NSColor { text.withAlphaComponent(0.09) }
    var highlight: NSColor { NSColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: isDark ? 0.35 : 0.65) }
    var cursor: NSColor { navy }

    // MARK: Palette of the keyword / result colours

    var navy: NSColor { pick(0x1F4468, 0x8CB8E8) }
    var teal: NSColor { pick(0x3E8A8A, 0x6CCBC4) }
    var sage: NSColor { pick(0x4F7B66, 0x8FC4A8) }
    var purple: NSColor { pick(0xB257E8, 0xCF8CF5) }
    /// `timer …` lines and the running timer.
    var timerColor: NSColor { pick(0xF0A04B, 0xFFC070) }
    /// Calculator results.
    var resultColor: NSColor { pick(0x5CA52F, 0x8BD45B) }

    func headingColor(level: Int) -> NSColor {
        [navy, teal, sage][min(max(level, 1), 3) - 1]
    }

    /// Colour of the keyword on the first line (`list`, `math` …).
    func keywordColor(_ mode: NoteMode) -> NSColor? {
        switch mode {
        case .plain: return nil
        case .math: return navy
        case .list: return purple
        case .sum: return pick(0x5BA832, 0x8BD45B)
        case .avg: return pick(0xF0A04B, 0xFFC070)
        case .count: return pick(0xE8453C, 0xFF7B72)
        }
    }

    /// Colour of the summary block drawn under `sum`, `avg` and `count` notes.
    func outputColor(_ style: OutputLine.Style) -> NSColor {
        switch style {
        case .sum: return pick(0x4A7F27, 0x8BD45B)
        case .avg: return pick(0xC77A2B, 0xFFB45A)
        case .count: return pick(0x9B2C2C, 0xFF8A80)
        }
    }

    // MARK: Themes

    static let all: [NoteTheme] = [
        NoteTheme(id: "paper", name: "Paper", background: rgb(0xFFFFFF), isDark: false),
        NoteTheme(id: "yellow", name: "Yellow", background: rgb(0xFFF2A8), isDark: false),
        NoteTheme(id: "pink", name: "Pink", background: rgb(0xFFD6E3), isDark: false),
        NoteTheme(id: "blue", name: "Blue", background: rgb(0xD3E9FF), isDark: false),
        NoteTheme(id: "green", name: "Green", background: rgb(0xD7F5CC), isDark: false),
        NoteTheme(id: "purple", name: "Purple", background: rgb(0xE6D9FF), isDark: false),
        NoteTheme(id: "orange", name: "Orange", background: rgb(0xFFE0BE), isDark: false),
        NoteTheme(id: "gray", name: "Gray", background: rgb(0xE8E8EA), isDark: false),
        NoteTheme(id: "graphite", name: "Graphite", background: rgb(0x2B2D33), isDark: true),
    ]

    static var fallback: NoteTheme { all[0] }

    static func named(_ id: String) -> NoteTheme {
        all.first { $0.id == id } ?? fallback
    }

    /// Colour names usable in `{name|text}`: (colour on light notes, colour on dark notes).
    static let namedColors: [String: (light: Int, dark: Int)] = [
        "red": (0xC62828, 0xFF7B7B),
        "orange": (0xD84315, 0xFFA45C),
        "yellow": (0xA67C00, 0xFFD84D),
        "green": (0x2E7D32, 0x7DDB82),
        "teal": (0x00796B, 0x5FD8C8),
        "blue": (0x1565C0, 0x6CB2FF),
        "purple": (0x6A1B9A, 0xC58BFF),
        "pink": (0xC2185B, 0xFF8FC0),
        "gray": (0x616161, 0xB0B0B0),
        "black": (0x000000, 0x000000),
        "white": (0xFFFFFF, 0xFFFFFF),
    ]

    /// Resolves `red`, `Blue`, `#FF8800` … to a colour that is readable on this theme.
    func color(named name: String) -> NSColor? {
        let key = name.lowercased()
        if key.hasPrefix("#"), key.count == 7, let hex = Int(key.dropFirst(), radix: 16) {
            return rgb(hex)
        }
        guard let pair = Self.namedColors[key] else { return nil }
        return rgb(isDark ? pair.dark : pair.light)
    }

    /// Small round swatch for menus.
    var swatch: NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            self.background.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}
