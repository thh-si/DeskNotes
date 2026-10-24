// swift-tools-version:6.0
// Swift 6 language mode: data races are compile errors. UI and storage code is @MainActor.
import PackageDescription

let package = Package(
    name: "DeskNotes",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure-Foundation logic (calculator, note modes) so it can be checked without any UI.
        .target(name: "NotesCore"),
        .executableTarget(name: "DeskNotes", dependencies: ["NotesCore"]),
        // `swift run CoreChecks` – assertions for the calculator (no XCTest needed).
        .executableTarget(name: "CoreChecks", dependencies: ["NotesCore"]),
        // Draws the app icon: `swift run IconMaker <output-dir>` (build.sh does this once).
        // A one-off drawing script built on top-level state; it stays in Swift 5 mode.
        .executableTarget(name: "IconMaker", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
