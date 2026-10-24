import AppKit
import SwiftUI
import NotesCore

/// The "All Notes" window: search, list or cards, select and delete, and the nine slots.
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    private let model: LibraryModel
    private unowned let manager: NoteManager

    init(manager: NoteManager) {
        self.manager = manager
        model = LibraryModel(store: manager.store)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)

        window.title = "All Notes"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 460)
        window.delegate = self
        window.contentView = NSHostingView(rootView: LibraryView(model: model))
        window.center()
        window.setFrameAutosaveName("DeskNotesAllNotes")

        model.onOpen = { [weak self] id in self?.manager.show(id) }
        model.onNewNote = { [weak self] in self?.manager.newNote() }
        model.onSetSlot = { [weak self] id, slot in self?.manager.setSlot(slot, for: id) }
        model.onDelete = { [weak self] ids in self?.confirmAndDelete(ids) }
        model.onClose = { [weak self] in self?.window?.performClose(nil) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        model.isActive = true
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        model.requestFocus()
    }

    func windowWillClose(_ notification: Notification) {
        model.isActive = false
        model.isSelecting = false
        model.query = ""
    }

    /// Notes with text are only deleted after you agree; the files go to the Trash.
    private func confirmAndDelete(_ ids: [UUID]) {
        let withText = ids.compactMap { manager.store.notes[$0] }.filter { !NoteLibrary.isEmpty($0) }.count
        guard withText > 0, let window else {
            manager.deleteNotes(ids)
            return
        }
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "Delete this note?" : "Delete \(ids.count) notes?"
        alert.informativeText = "The note files are moved to the Trash, so you can still recover them from there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        Task {
            if await alert.beginSheetModal(for: window) == .alertFirstButtonReturn {
                manager.deleteNotes(ids)
            }
        }
    }
}
