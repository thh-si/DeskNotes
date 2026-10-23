// swift-tools-version:5.9
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
        .executableTarget(name: "IconMaker"),
    ]
)
