#!/bin/bash
# Builds build/DeskNotes.app (needs Xcode or the Command Line Tools; no Xcode project required).
#   ./build.sh                  build the app
#   REGENERATE_ICON=1 ./build.sh   also redraw the icon (Sources/IconMaker); ICON_STYLE=desk for the violet desk icon
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DeskNotes.app"

# App icon: drawn by IconMaker, kept as Resources/AppIcon.icns.
if [ ! -f Resources/AppIcon.icns ] || [ "${REGENERATE_ICON:-0}" = "1" ]; then
    swift build -c release --product IconMaker
    mkdir -p build/icon
    "$(swift build -c release --show-bin-path)/IconMaker" build/icon "${ICON_STYLE:-apple}"
    iconutil -c icns build/icon/AppIcon.iconset -o Resources/AppIcon.icns
fi

swift build -c release --product DeskNotes
BIN="$(swift build -c release --show-bin-path)/DeskNotes"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeskNotes"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough for running locally and for "Launch at Login".
codesign --force --sign - "$APP"

echo
echo "Built $APP"
echo "Install:  cp -R \"$APP\" ~/Applications/ && open ~/Applications/DeskNotes.app"
