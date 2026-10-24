import Foundation

/// Which notes the "All Notes" window shows.
public enum LibraryScope: String, CaseIterable, Sendable {
    case all
    /// Only the notes kept in slots, in slot order.
    case slotted
}

/// Searching, ordering and previewing notes for the "All Notes" window.
public enum NoteLibrary {
    /// Lower-case, accent-free copies of note texts, kept between searches. Comparing "ignoring case
    /// and accents" costs about half a millisecond per large note; looking in a copy that is already
    /// folded is a plain substring search, many times faster, so a keystroke in the search field stays instant.
    public struct SearchIndex {
        private var entries: [UUID: (stamp: Stamp, folded: String)] = [:]

        private struct Stamp: Equatable {
            let modified: Date
            let length: Int
        }

        public init() {}

        public static func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }

        /// The folded text of a note; only recomputed when the note has changed since last time.
        public mutating func folded(_ note: Note) -> String {
            let stamp = Stamp(modified: note.modified, length: note.text.utf16.count)
            if let entry = entries[note.id], entry.stamp == stamp { return entry.folded }
            let folded = Self.fold(note.text)
            entries[note.id] = (stamp, folded)
            return folded
        }

        /// Forgets deleted notes.
        public mutating func keep(only ids: Set<UUID>) {
            if entries.count > ids.count { entries = entries.filter { ids.contains($0.key) } }
        }
    }

    /// The notes to list. `all` is newest-edited first; `slotted` is slot 1 to 9. A search matches
    /// notes that contain every word of the query, ignoring case and accents.
    public static func visible(_ notes: [Note], query: String, scope: LibraryScope) -> [Note] {
        var index = SearchIndex()
        return visible(notes, query: query, scope: scope, index: &index)
    }

    /// The same, reusing `index` between calls (the window keeps one while it is open).
    public static func visible(_ notes: [Note], query: String, scope: LibraryScope, index: inout SearchIndex) -> [Note] {
        let words = query.split(whereSeparator: \.isWhitespace).map { SearchIndex.fold(String($0)) }
        var result = scope == .all ? notes : notes.filter { $0.slot != nil }
        if !words.isEmpty {
            result = result.filter { note in
                let text = index.folded(note)
                return words.allSatisfy { text.contains($0) }
            }
        }
        index.keep(only: Set(notes.map(\.id)))
        switch scope {
        case .all:
            // A tie (same edit time) is broken by creation, then by id, so the order never jumps.
            result.sort { ($0.modified, $0.created, $0.id.uuidString) > ($1.modified, $1.created, $1.id.uuidString) }
        case .slotted:
            result.sort { ($0.slot ?? .max) < ($1.slot ?? .max) }
        }
        return result
    }

    /// The first non-empty lines of a note, trimmed, for a preview.
    public static func previewLines(_ text: String, maxLines: Int) -> [String] {
        var lines: [String] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            lines.append(line.count > 300 ? String(line.prefix(300)) + "…" : line)
            if lines.count == maxLines { break }
        }
        return lines
    }

    public static func isEmpty(_ note: Note) -> Bool {
        note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
