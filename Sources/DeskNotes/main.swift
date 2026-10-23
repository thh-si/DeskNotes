import AppKit

// `DeskNotes --snapshot <dir>`: render sample notes to PNG and exit (design check, see Snapshot.swift).
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), flag + 1 < CommandLine.arguments.count {
    Snapshot.run(outputDir: CommandLine.arguments[flag + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon, no app menu: DeskNotes lives in the menu bar. (Info.plist sets LSUIElement too.)
app.setActivationPolicy(.accessory)
app.run()
