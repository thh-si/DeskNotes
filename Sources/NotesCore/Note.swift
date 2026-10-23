import CoreGraphics
import Foundation

public struct Note: Codable {
    public var id = UUID()
    public var text = ""
    public var themeID = "paper"
    public var frame = CGRect(x: 200, y: 200, width: 300, height: 300)
    /// Whether the note's window is shown. Closing a window only hides the note.
    public var isVisible = true
    /// Float above other apps' windows.
    public var floats = false
    /// Show on every desktop (Space).
    public var allSpaces = false
    public var created = Date()
    public var modified = Date()

    public init() {}

    // Tolerant decoding: files written by older/newer versions with missing keys still load.
    // Missing keys take the same defaults as a new note.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Note()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? defaults.id
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? defaults.text
        themeID = try c.decodeIfPresent(String.self, forKey: .themeID) ?? defaults.themeID
        frame = try c.decodeIfPresent(CGRect.self, forKey: .frame) ?? defaults.frame
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? defaults.isVisible
        floats = try c.decodeIfPresent(Bool.self, forKey: .floats) ?? defaults.floats
        allSpaces = try c.decodeIfPresent(Bool.self, forKey: .allSpaces) ?? defaults.allSpaces
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? defaults.created
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? defaults.modified
    }

    /// First meaningful line, for the menu bar list.
    public var title: String {
        var lines: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "#>-*+ ".contains(first) { line.removeFirst() }
            if !line.isEmpty { lines.append(line) }
            if lines.count == 2 { break }
        }
        guard var title = lines.first else { return "Empty note" }
        // A mode keyword alone on the first line ("math", "list") is no title: add the next line.
        let keywords = ["math", "list", "sum", "avg", "count"]
        if keywords.contains(title.lowercased()), lines.count > 1 { title += " · " + lines[1] }
        return title.count > 42 ? String(title.prefix(42)) + "…" : title
    }
}

/// Keeps every note as one JSON file in `~/Library/Application Support/DeskNotes/Notes`,
/// written shortly after each change. Deleted notes go to the Trash, not into the void.
public final class NoteStore {
    public static let shared: NoteStore = {
        if let override = ProcessInfo.processInfo.environment["DESKNOTES_DIR"] {
            return NoteStore(directory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return NoteStore(directory: base.appendingPathComponent("DeskNotes/Notes", isDirectory: true))
    }()

    public private(set) var notes: [UUID: Note] = [:]
    public let directory: URL
    private var dirty = Set<UUID>()
    private var pendingSave: DispatchWorkItem?

    /// Changes that are not on disk yet (waiting for the save delay, or a save that failed).
    public var hasUnsavedChanges: Bool { !dirty.isEmpty }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let note = try? decoder.decode(Note.self, from: data) else {
                NSLog("DeskNotes: skipping unreadable note file \(file.lastPathComponent)")
                continue
            }
            notes[note.id] = note
        }
    }

    public func add(_ note: Note) {
        notes[note.id] = note
        scheduleSave(note.id)
    }

    /// `touch: false` for changes that aren't edits (window moved, colour changed …).
    public func update(_ id: UUID, touch: Bool = true, _ change: (inout Note) -> Void) {
        guard var note = notes[id] else { return }
        change(&note)
        if touch { note.modified = Date() }
        notes[id] = note
        scheduleSave(id)
    }

    public func remove(_ id: UUID) {
        notes[id] = nil
        dirty.remove(id)
        let file = fileURL(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        if (try? FileManager.default.trashItem(at: file, resultingItemURL: nil)) == nil {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Writes every changed note. A note that can't be written (disk full, no permission …) stays
    /// marked as changed: it is tried again in a few seconds, on the next edit and on quit.
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        for id in dirty {
            guard let note = notes[id] else {
                dirty.remove(id)
                continue
            }
            do {
                try encoder.encode(note).write(to: fileURL(id), options: .atomic)
                dirty.remove(id)
            } catch {
                NSLog("DeskNotes: could not save note \(id): \(error)")
            }
        }
        if !dirty.isEmpty { scheduleFlush(after: 10) }
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func scheduleSave(_ id: UUID) {
        dirty.insert(id)
        scheduleFlush(after: 0.4)
    }

    private func scheduleFlush(after delay: TimeInterval) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
