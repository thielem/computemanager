#!/usr/bin/env bash
# Build ComputeManager (release) and assemble an ad-hoc signed build/ComputeManager.app.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/swiftw build -c release --product ComputeManager -q
BIN="$(scripts/swiftw build -c release --show-bin-path)/ComputeManager"

APP=build/ComputeManager.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ComputeManager"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CMRepoPath $PWD" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --timestamp=none "$APP"
codesign --verify "$APP"
echo "$APP"
