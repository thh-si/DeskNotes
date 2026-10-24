#!/bin/bash
# Builds build.noindex/DeskNotes.app (needs Xcode or the Command Line Tools; no Xcode project required).
#   ./build.sh                       build the app for this Mac
#   ARCHS="arm64 x86_64" ./build.sh  universal app (Apple Silicon + Intel); make-dmg.sh does this
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
#                                    sign with your certificate instead of ad-hoc (see make-dmg.sh)
#   REGENERATE_ICON=1 ./build.sh     also redraw the icon (Sources/IconMaker); ICON_STYLE=desk for the violet desk icon
set -euo pipefail
cd "$(dirname "$0")"

APP="build.noindex/DeskNotes.app"

# App icon: drawn by IconMaker, kept as Resources/AppIcon.icns.
if [ ! -f Resources/AppIcon.icns ] || [ "${REGENERATE_ICON:-0}" = "1" ]; then
    swift build -c release --product IconMaker
    mkdir -p build.noindex/icon
    "$(swift build -c release --show-bin-path)/IconMaker" build.noindex/icon "${ICON_STYLE:-apple}"
    iconutil -c icns build.noindex/icon/AppIcon.iconset -o Resources/AppIcon.icns
fi

ARCH_FLAGS=()
for arch in ${ARCHS:-}; do ARCH_FLAGS+=(--arch "$arch"); done

# (The ${…+…} form keeps an empty array from tripping `set -u` in macOS's old bash.)
swift build -c release --product DeskNotes ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})/DeskNotes"

# The app is assembled, signed and checked in a temporary folder, then copied to build.noindex/. A folder
# synced by iCloud (like the Desktop) gets extra attributes (Finder info, file-provider flags) at
# random moments, and the strict signature check rejects them; the temporary folder is not synced.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BUILT="$WORK/DeskNotes.app"
mkdir -p "$BUILT/Contents/MacOS" "$BUILT/Contents/Resources"
cp "$BIN" "$BUILT/Contents/MacOS/DeskNotes"
cp Resources/Info.plist "$BUILT/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUILT/Contents/Resources/AppIcon.icns"

# Always sandboxed (Resources/DeskNotes.entitlements) and with the hardened runtime.
# Without SIGN_IDENTITY: an ad-hoc signature, enough for running on this Mac and for "Launch at Login".
# With a Developer ID certificate: hardened runtime + timestamp, which notarization requires.
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --entitlements Resources/DeskNotes.entitlements --sign "$SIGN_IDENTITY" "$BUILT"
else
    codesign --force --options runtime --entitlements Resources/DeskNotes.entitlements --sign - "$BUILT"
fi
codesign --verify --deep --strict "$BUILT"

rm -rf "$APP"
mkdir -p build
ditto "$BUILT" "$APP"
xattr -cr "$APP"
codesign --verify --deep "$APP"

echo
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/DeskNotes"))"
echo "Install / share:  ./make-dmg.sh, then open the .dmg and drag DeskNotes onto Applications"
