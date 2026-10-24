#!/bin/bash
# Packs DeskNotes into a disk image you can send to other people: build.noindex/DeskNotes-<version>.dmg
# It opens to the app and a shortcut to Applications, so installing is one drag.
#
#   ./make-dmg.sh      universal app (Apple Silicon + Intel), signed ad-hoc
#
# Other Macs: an ad-hoc signed app is blocked by Gatekeeper the first time ("cannot be opened because
# the developer cannot be verified"). The disk image then carries a short "Read Me First" that shows
# how to open it anyway. To avoid that for good you need an Apple Developer account ($99 a year):
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="desknotes-notary" ./make-dmg.sh
#
# SIGN_IDENTITY signs the app (and the image) with your certificate; NOTARY_PROFILE is a keychain
# profile made once with:  xcrun notarytool store-credentials desknotes-notary
# The image is then notarized and stapled, and opens on any Mac without a warning.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS="${ARCHS:-arm64 x86_64}" ./build.sh

APP="build.noindex/DeskNotes.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
# "beta 1" from Info.plist (DeskNotesChannel); empty for a final release.
CHANNEL="$(/usr/libexec/PlistBuddy -c 'Print DeskNotesChannel' Resources/Info.plist 2>/dev/null || true)"
DMG="build.noindex/DeskNotes-$VERSION${CHANNEL:+-${CHANNEL// /}}.dmg"
VOLUME="DeskNotes $VERSION${CHANNEL:+ $CHANNEL}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
# Folders synced by iCloud pick up extra attributes (Finder info, file-provider flags) that make a
# strict signature check fail. Clear them on the copy and check the signature before packing.
xattr -cr "$STAGE/DeskNotes.app"
codesign --verify --deep --strict "$STAGE/DeskNotes.app"
ln -s /Applications "$STAGE/Applications"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    cat > "$STAGE/Read Me First.txt" <<'EOF'
DeskNotes
=========

1. Drag DeskNotes onto the Applications folder.
2. The first time, macOS may say it cannot verify the developer, because this app is not
   from the App Store. To open it anyway:

   - Right-click (or Control-click) DeskNotes in Applications, choose Open, then Open again.
   or
   - System Settings > Privacy & Security > scroll down > "Open Anyway".
   or, in Terminal:   xattr -dr com.apple.quarantine /Applications/DeskNotes.app

You only need to do this once.

DeskNotes lives in the menu bar (look for the small screen with a note in it). Option-Command-N makes a new note.
Allow notifications when asked, so reminders and the Pomodoro timer can reach you.
EOF
fi

if [ -n "$CHANNEL" ]; then
    printf '\nThis is a %s: expect rough edges. Your notes are kept in\n~/Library/Containers/local.desknotes.app/Data/Library/Application Support/DeskNotes/Notes,\nso removing or updating the app never deletes them.\n' "$CHANNEL" >> "$STAGE/Read Me First.txt"
fi

rm -f "$DMG"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -ov "$DMG" > /dev/null

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

hdiutil verify "$DMG" > /dev/null
echo
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
