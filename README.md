# DeskNotes

Quick notes on your Mac desktop, one keystroke away. A menu-bar app (no Dock icon) with Markdown,
coloured text, an inline calculator, checklists, timers and reminders. Notes stay on your Mac.

## Install

1. Download `DeskNotes-<version>.dmg` from the [Releases](../../releases) page and drag DeskNotes to Applications.
2. The app is not notarized (that needs a paid Apple Developer account), so macOS blocks the first launch.
   Either right-click the app, choose **Open**, then **Open** again, or run:
   `xattr -dr com.apple.quarantine /Applications/DeskNotes.app`

Needs macOS 13 or newer. Apple Silicon and Intel.

## Privacy and sandbox

DeskNotes runs in the macOS **App Sandbox** and asks for no other permission: no network, no access to
your files. Notes are plain JSON files in the app's container:

    ~/Library/Containers/local.desknotes.app/Data/Library/Application Support/DeskNotes/Notes

Deleted notes go to the Trash. Reminders and timers use notifications; macOS asks once.

## Build from source

Needs Xcode or the Command Line Tools.

    ./build.sh       # build.noindex/DeskNotes.app
    ./make-dmg.sh    # universal disk image
    swift run CoreChecks   # calculator and note-analysis checks

## License

MIT, see [LICENSE](LICENSE).
