import CoreGraphics
import Foundation

public struct Note: Codable, Sendable {
    /// Version of the file format. Bump it when a field changes meaning or shape and migrate older
    /// files in `init(from:)`. New fields don't need a bump: missing keys get defaults below.
    public static let currentFormat = 1

    /// Format of the file this note came from; always `currentFormat` once loaded and when saved.
    public private(set) var format = Note.currentFormat
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
    /// 1 is solid paper; lower lets the desktop show through a frosted blur.
    public var opacity = 1.0
    /// When to send a notification about this note. Cleared once it has fired.
    public var reminder: Date?
    /// Notes can be kept in one of nine slots (1 to 9) for quick access; a slot holds one note.
    public var slot: Int?

    public static let slotRange = 1...9

    /// Transparency is limited, so text always stays readable.
    public static let opacityRange = 0.35...1.0
    /// The choices offered in the colour menu.
    public static let opacityPresets = [1.0, 0.85, 0.7, 0.55, 0.4]

    public static func clampOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }

    public init() {}

    // Tolerant decoding: files written by older/newer versions with missing keys still load.
    // Missing keys take the same defaults as a new note.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Files from before the version field are format 1. A newer format is refused, so this
        // version never overwrites a file it can't fully understand.
        let fileFormat = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        guard fileFormat <= Note.currentFormat else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c,
                debugDescription: "written by a newer DeskNotes (format \(fileFormat))")
        }
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
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity).map(Note.clampOpacity) ?? defaults.opacity
        reminder = try c.decodeIfPresent(Date.self, forKey: .reminder)
        slot = try c.decodeIfPresent(Int.self, forKey: .slot).flatMap { Note.slotRange.contains($0) ? $0 : nil }
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
        if NoteMode.keywords.contains(title.lowercased()), lines.count > 1 { title += " · " + lines[1] }
        return title.count > 42 ? String(title.prefix(42)) + "…" : title
    }
}

/// Keeps every note as one JSON file in `~/Library/Application Support/DeskNotes/Notes`,
/// written shortly after each change. Deleted notes go to the Trash, not into the void.
/// Used from the main thread only, like the windows that edit the notes.
@MainActor
public final class NoteStore {
    public static let shared: NoteStore = {
        if let override = ProcessInfo.processInfo.environment["DESKNOTES_DIR"] {
            return NoteStore(directory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return NoteStore(directory: base.appendingPathComponent("DeskNotes/Notes", isDirectory: true))
    }()

    /// Posted (on the main thread) whenever a note is added, changed, removed or loaded, so windows
    /// that list notes can refresh. The object is the store.
    public static let didChange = Notification.Name("DeskNotes.NoteStore.didChange")

    public private(set) var notes: [UUID: Note] = [:]
    public let directory: URL
    private var dirty = Set<UUID>()
    private var pendingSave: Task<Void, Never>?
    /// Where each loaded note lives. Normally `<id>.json`, but a renamed or copied file keeps its
    /// name, so saving doesn't leave a second file with the same note behind.
    private var files: [UUID: URL] = [:]

    /// Changes that are not on disk yet (waiting for the save delay, or a save that failed).
    public var hasUnsavedChanges: Bool { !dirty.isEmpty }

    public init(directory: URL) {
        self.directory = directory
        // Notes are private: owner-only folder and files (also fixes a folder made by an older version).
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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
        let found = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        // Sorted, so that when two files hold the same note the same one wins every time.
        for file in found.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            let note: Note
            do {
                note = try decoder.decode(Note.self, from: Data(contentsOf: file))
            } catch {
                // Left untouched on disk, so nothing is lost.
                NSLog("DeskNotes: skipping note file \(file.lastPathComponent): \(error)")
                continue
            }
            if let existing = files[note.id] {
                NSLog("DeskNotes: \(file.lastPathComponent) holds the same note as \(existing.lastPathComponent); ignoring it")
                continue
            }
            notes[note.id] = note
            files[note.id] = file
        }
        notifyChange()
    }

    public func add(_ note: Note) {
        notes[note.id] = note
        scheduleSave(note.id)
        notifyChange()
    }

    /// `touch: false` for changes that aren't edits (window moved, colour changed …).
    public func update(_ id: UUID, touch: Bool = true, _ change: (inout Note) -> Void) {
        guard var note = notes[id] else { return }
        change(&note)
        if touch { note.modified = Date() }
        notes[id] = note
        scheduleSave(id)
        notifyChange()
    }

    /// Puts a note in slot 1 to 9, or takes it out of its slot (nil). A slot holds one note, so
    /// whoever was in it before loses it.
    public func assignSlot(_ slot: Int?, to id: UUID) {
        guard notes[id] != nil else { return }
        if let slot {
            guard Note.slotRange.contains(slot) else { return }
            for (otherID, other) in notes where other.slot == slot && otherID != id {
                update(otherID, touch: false) { $0.slot = nil }
            }
        }
        update(id, touch: false) { $0.slot = slot }
    }

    /// The note in a slot, if any.
    public func note(inSlot slot: Int) -> Note? {
        notes.values.first { $0.slot == slot }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func remove(_ id: UUID) {
        notes[id] = nil
        dirty.remove(id)
        defer { notifyChange() }
        let file = fileURL(id)
        files[id] = nil
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        if (try? FileManager.default.trashItem(at: file, resultingItemURL: nil)) != nil { return }
        // The Trash isn't available (some volumes): keep the file in a folder next to the notes
        // instead of deleting it for good.
        let kept = directory.deletingLastPathComponent().appendingPathComponent("Deleted Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let target = kept.appendingPathComponent(file.lastPathComponent)
        if (try? FileManager.default.moveItem(at: file, to: target)) == nil {
            // Last resort: the file stays where it is. It reappears at the next launch, which is
            // better than losing a note without a trace.
            NSLog("DeskNotes: could not remove \(file.lastPathComponent) from the notes folder")
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
                let file = fileURL(id)
                try encoder.encode(note).write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                dirty.remove(id)
            } catch {
                NSLog("DeskNotes: could not save note \(id): \(error)")
            }
        }
        if !dirty.isEmpty { scheduleFlush(after: 10) }
    }

    private func fileURL(_ id: UUID) -> URL {
        files[id] ?? directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func scheduleSave(_ id: UUID) {
        dirty.insert(id)
        scheduleFlush(after: 0.4)
    }

    private func scheduleFlush(after delay: TimeInterval) {
        pendingSave?.cancel()
        // Runs on the main actor, like the rest of the store.
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
