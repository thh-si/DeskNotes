import SwiftUI
import NotesCore

enum LibraryLayout {
    case list, grid
}

/// What the "All Notes" window shows and does. The notes themselves stay in the `NoteStore`; this
/// holds the search, the view, the selection, and the actions the window controller supplies.
@MainActor
final class LibraryModel: ObservableObject {
    @Published var query = "" { didSet { reload() } }
    @Published var scope = LibraryScope.all { didSet { reload() } }
    @Published var layout = LibraryLayout.list
    @Published var isSelecting = false { didSet { if !isSelecting { selection.removeAll() } } }
    @Published var selection = Set<UUID>()
    @Published private(set) var notes: [Note] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var slottedCount = 0
    /// Bumped to move the cursor into the search field.
    @Published private(set) var focusToken = 0

    var onOpen: @MainActor (UUID) -> Void = { _ in }
    var onDelete: @MainActor ([UUID]) -> Void = { _ in }
    var onNewNote: @MainActor () -> Void = {}
    var onSetSlot: @MainActor (UUID, Int?) -> Void = { _, _ in }
    var onClose: @MainActor () -> Void = {}

    /// Only refreshes while the window is open: notes change on every keystroke elsewhere.
    var isActive = false { didSet { if isActive { reload() } } }

    private let store: NoteStore
    private var searchIndex = NoteLibrary.SearchIndex()

    init(store: NoteStore) {
        self.store = store
        NotificationCenter.default.addObserver(forName: NoteStore.didChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isActive == true { self?.reload() } }  // posted on the main thread
        }
        reload()
    }

    func reload() {
        let everything = Array(store.notes.values)
        totalCount = everything.count
        slottedCount = everything.filter { $0.slot != nil }.count
        notes = NoteLibrary.visible(everything, query: query, scope: scope, index: &searchIndex)
        let shown = Set(notes.map(\.id))
        if !selection.isSubset(of: shown) { selection.formIntersection(shown) }
    }

    func requestFocus() { focusToken += 1 }

    /// Esc: clear the search, then leave select mode, then close the window.
    func escape() {
        if !query.isEmpty { query = "" } else if isSelecting { isSelecting = false } else { onClose() }
    }

    /// A tap on a note: open it, or tick it while selecting.
    func tap(_ id: UUID) {
        guard isSelecting else { onOpen(id); return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func selectAllShown() { selection = Set(notes.map(\.id)) }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        onDelete(Array(selection))
    }

    /// "1 hour ago" for recent notes, otherwise the date; "Edited" when it was changed after it was made.
    static func dateText(for note: Note, now: Date = Date()) -> String {
        let age = now.timeIntervalSince(note.modified)
        if age < 45 { return "Just now" }
        if age < 2 * 86_400 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: note.modified, relativeTo: now)
        }
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDate(note.modified, equalTo: now, toGranularity: .year) ? "dMMMM" : "dMMMMyyyy")
        let edited = note.modified.timeIntervalSince(note.created) > 60
        return (edited ? "Edited " : "") + day.string(from: note.modified)
    }
}

// MARK: - Look

/// A capsule of Liquid Glass on macOS 26 and later, a frosted capsule before.
private struct GlassCapsule: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if Glass.isAvailable, #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

private extension View {
    func glassCapsule() -> some View { modifier(GlassCapsule()) }
}

/// The small square buttons on notes (open, delete, new note).
private struct IconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: 26)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The first lines of a note, in the note's own style: a mode word or timer line keeps its colour.
private enum Preview {
    static func text(for note: Note, lines maxLines: Int, joined: Bool, themed: Bool) -> Text {
        let theme = NoteTheme.named(note.themeID)
        let lines = NoteLibrary.previewLines(note.text, maxLines: maxLines)
        let font = Font.system(size: 12, design: .monospaced)
        guard !lines.isEmpty else { return Text("Empty note").font(font).foregroundColor(.secondary) }

        var attributed = AttributedString(lines.joined(separator: joined ? "  |  " : "\n"))
        if themed { attributed.foregroundColor = Color(nsColor: theme.text) }
        if let first = lines.first, let accent = accent(for: first, theme: theme), let range = attributed.range(of: first) {
            attributed[range].foregroundColor = Color(nsColor: accent)
        }
        return Text(attributed).font(font)
    }

    private static func accent(for line: String, theme: NoteTheme) -> NSColor? {
        if TimerCommand.parse(line) != nil { return theme.timerColor }
        let word = (line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? line)
            .trimmingCharacters(in: .whitespaces).lowercased()
        if let mode = NoteMode(rawValue: word), mode != .plain { return theme.keywordColor(mode) }
        return nil
    }
}

// MARK: - Pieces shared by rows and cards

private struct NoteActions: View {
    @ObservedObject var model: LibraryModel
    let note: Note

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(Array(Note.slotRange), id: \.self) { slot in
                    Button((note.slot == slot ? "✓ " : "") + "Slot \(slot)") { model.onSetSlot(note.id, slot) }
                }
                if note.slot != nil {
                    Divider()
                    Button("Remove from Slot") { model.onSetSlot(note.id, nil) }
                }
            } label: {
                Image(systemName: note.slot == nil ? "pin" : "pin.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: 26)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Keep in a slot (⌥⌘1 to ⌥⌘9 opens it)")

            IconButton(symbol: "arrow.up.to.line", help: "Open note") { model.onOpen(note.id) }
            IconButton(symbol: "trash", help: "Delete note…") { model.onDelete([note.id]) }
        }
    }
}

private struct SelectionCircle: View {
    let isOn: Bool

    var body: some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18))
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.6))
    }
}

private struct MetaLine: View {
    let note: Note

    var body: some View {
        HStack(spacing: 6) {
            if let slot = note.slot {
                Text("SLOT \(slot)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            Text(LibraryModel.dateText(for: note))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - List row and card

private struct NoteRowView: View {
    @ObservedObject var model: LibraryModel
    let note: Note

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if model.isSelecting { SelectionCircle(isOn: model.selection.contains(note.id)).padding(.top, 2) }
            VStack(alignment: .leading, spacing: 5) {
                Preview.text(for: note, lines: 4, joined: true, themed: false)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MetaLine(note: note)
            }
            NoteActions(model: model, note: note)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(model.selection.contains(note.id) ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.tap(note.id) }
    }
}

private struct NoteCardView: View {
    @ObservedObject var model: LibraryModel
    let note: Note

    private var theme: NoteTheme { NoteTheme.named(note.themeID) }
    private var isSelected: Bool { model.selection.contains(note.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isSelecting {
                SelectionCircle(isOn: isSelected)
            }
            Preview.text(for: note, lines: 7, joined: false, themed: true)
                .lineLimit(7)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                MetaLine(note: note)
                Spacer(minLength: 4)
                NoteActions(model: model, note: note)
            }
        }
        .environment(\.colorScheme, theme.isDark ? .dark : .light)  // dates and buttons readable on dark notes
        .padding(14)
        .frame(minHeight: 170, alignment: .topLeading)
        .background(Color(nsColor: theme.background), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.14), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { model.tap(note.id) }
    }
}

// MARK: - The window

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                searchField
                content
            }
            bottomBar
        }
        .frame(minWidth: 400, minHeight: 460)
        .onReceive(model.$focusToken) { _ in searchFocused = true }
    }

    // MARK: Top

    private var header: some View {
        HStack(spacing: 10) {
            Spacer()
            Text(model.scope == .all ? "\(model.totalCount) notes" : "\(model.slottedCount) of 9 slots")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            IconButton(symbol: "square.and.pencil", help: "New note") { model.onNewNote() }
        }
        .padding(.leading, 84)  // room for the window's close, minimise and zoom buttons
        .padding(.trailing, 18)
        .padding(.top, 8)
        .frame(height: 46)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .onExitCommand { model.escape() }
            Text("esc")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    // MARK: Notes

    @ViewBuilder
    private var content: some View {
        if model.notes.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text(emptyTitle).font(.headline)
                Text(emptyDetail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
        } else if model.layout == .list {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.notes, id: \.id) { note in
                        NoteRowView(model: model, note: note)
                        Divider().padding(.leading, 18)
                    }
                }
                .padding(.bottom, 96)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(model.notes, id: \.id) { note in
                        NoteCardView(model: model, note: note)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 96)
            }
        }
    }

    private var emptyTitle: String {
        if !model.query.isEmpty { return "No notes match “\(model.query)”" }
        return model.scope == .slotted ? "No notes in slots yet" : "No notes yet"
    }

    private var emptyDetail: String {
        if !model.query.isEmpty { return "Try fewer words." }
        return model.scope == .slotted
            ? "Use the pin button on a note to keep it in a slot. ⌥⌘1 to ⌥⌘9 then opens it from anywhere."
            : "Press ⌥⌘N to write one."
    }

    // MARK: Bottom

    private var bottomBar: some View {
        HStack(spacing: 10) {
            selectControls
            Spacer(minLength: 0)
            if !model.isSelecting {  // no room for it next to the selection buttons
                Button {
                    model.scope = model.scope == .all ? .slotted : .all
                } label: {
                    pillLabel(model.scope == .all ? "All Notes" : "Slotted",
                              symbol: model.scope == .all ? "square.stack" : "square.grid.3x3.fill")
                }
                .buttonStyle(.plain)
                .glassCapsule()
                .help(model.scope == .all ? "Show the notes in slots" : "Show all notes")
                Spacer(minLength: 0)
            }
            layoutToggle
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var selectControls: some View {
        HStack(spacing: 8) {
            Button {
                model.isSelecting.toggle()
            } label: {
                pillLabel(model.isSelecting ? "Done" : "Select",
                          symbol: model.isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .buttonStyle(.plain)
            .glassCapsule()

            if model.isSelecting {
                Button { model.selectAllShown() } label: {
                    Text("All").font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).frame(height: 36).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassCapsule()
                if !model.selection.isEmpty {
                    Button(role: .destructive) { model.deleteSelected() } label: {
                        pillLabel("Delete \(model.selection.count)", symbol: "trash").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .glassCapsule()
                }
            }
        }
    }

    /// An icon and a word inside a pill (`Label` would drop the icon in some button styles).
    private func pillLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 36)
        .contentShape(Capsule())
    }

    private var layoutToggle: some View {
        HStack(spacing: 2) {
            layoutButton(.list, symbol: "list.bullet", help: "List")
            layoutButton(.grid, symbol: "square.grid.2x2", help: "Cards")
        }
        .padding(3)
        .glassCapsule()
    }

    private func layoutButton(_ layout: LibraryLayout, symbol: String, help: String) -> some View {
        let isOn = model.layout == layout
        return Button {
            model.layout = layout
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .frame(width: 40, height: 30)
                .background(isOn ? Color.primary.opacity(0.85) : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
