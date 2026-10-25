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

DeskNotes is free and not notarized by Apple (that needs a paid developer account), so macOS
blocks the first launch. This takes a minute, once.

1. Drag DeskNotes onto the Applications folder. Then eject this disk image.
   Don't open DeskNotes from here, only from Applications.

2. Open DeskNotes from Applications. macOS says it "can't be opened" or that it could not
   verify DeskNotes. Click "Done" - NOT "Move to Trash".

3. Open System Settings > Privacy & Security and scroll down to "Security". Next to
   "DeskNotes was blocked..." click "Open Anyway", confirm with your password or Touch ID,
   then click "Open Anyway" once more.
   (The button only shows up for a while after step 2. If it's gone, repeat step 2.)

   Or instead of steps 2 and 3, paste this into Terminal and press Return:

       xattr -dr com.apple.quarantine /Applications/DeskNotes.app && open /Applications/DeskNotes.app

   On macOS 13 and 14, right-click DeskNotes in Applications > Open > Open works too.

The very first start can take a few seconds while macOS checks the app.

DeskNotes has no Dock icon. It opens a welcome note and lives in the menu bar (a small screen
with a note in it; on a MacBook with many menu bar icons it can hide behind the camera notch).
Option-Command-N makes a new note, Option-Command-J shows or hides all notes.
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
