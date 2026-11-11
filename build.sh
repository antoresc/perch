#!/bin/bash
# Builds Perch and installs it to /Applications.
# Build products go to ~/Library/Caches so thousands of temp files don't sync to Google Drive.
set -euo pipefail
cd "$(dirname "$0")"

SCRATCH="$HOME/Library/Caches/PerchBuild"
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"

APP="$SCRATCH/Perch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/Perch" "$APP/Contents/MacOS/Perch"
cp "$BIN/perch-hook" "$APP/Contents/MacOS/perch-hook"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Signed locally ("ad hoc"): enough for macOS to run it on this Mac, no developer account needed.
codesign --force --sign - "$APP/Contents/MacOS/perch-hook"
codesign --force --sign - "$APP"

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x Perch 2>/dev/null || true
rm -rf "$DEST/Perch.app"
cp -R "$APP" "$DEST/Perch.app"
echo "Installed $DEST/Perch.app"
