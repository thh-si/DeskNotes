# DeskNotes

Quick notes on your Mac desktop, one keystroke away. A menu-bar app (no Dock icon) with Markdown,
coloured text, an inline calculator, checklists, timers and reminders. Notes stay on your Mac.

## Install

1. Download `DeskNotes-<version>.dmg` from the [Releases](../../releases) page, drag DeskNotes to
   Applications and eject the disk image. Open DeskNotes from Applications, not from the disk image.
2. The app is not notarized (that needs a paid Apple Developer account), so macOS blocks the first launch
   and offers **Move to Trash**. Click **Done** instead, then go to **System Settings › Privacy & Security**,
   click **Open Anyway** next to "DeskNotes was blocked", confirm, and click **Open Anyway** again.
   Right-click › **Open** no longer does this on macOS 15 and later. Or run this once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/DeskNotes.app && open /Applications/DeskNotes.app
   ```

3. DeskNotes has no Dock icon: it opens a welcome note and lives in the menu bar (on a crowded MacBook
   menu bar the icon can hide behind the notch). ⌥⌘N makes a new note, ⌥⌘J shows or hides all notes.

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
