#!/usr/bin/env bash
# Build ComputeManager, fand and cgate (release) and assemble a signed ComputeManager.app:
#   Contents/MacOS/{ComputeManager,fand,cgate}
#   Contents/Resources/{AppIcon.icns,<fand label>.plist,install-fand.sh,uninstall-fand.sh}
# Env (all optional; scripts/release.sh sets them):
#   CM_APP         output path            (default build/ComputeManager.app)
#   CM_VERSION     sets CFBundleShortVersionString + CFBundleVersion
#   CM_RELEASE=1   don't set CMRepoPath   (dev builds point the app at this checkout)
#   SIGN_IDENTITY  Developer ID identity  (default: ad-hoc; set → hardened runtime + timestamp)
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=com.moritzthiele.cgate.fand
APP=${CM_APP:-build/ComputeManager.app}

for p in ComputeManager fand cgate; do
  scripts/swiftw build -c release --product "$p" -q
done
BIN="$(scripts/swiftw build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for p in ComputeManager fand cgate; do cp "$BIN/$p" "$APP/Contents/MacOS/$p"; done
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "packaging/launchd/$LABEL.plist" scripts/install-fand.sh scripts/uninstall-fand.sh \
  "$APP/Contents/Resources/"

PB() { /usr/libexec/PlistBuddy -c "$1" "$APP/Contents/Info.plist"; }
if [[ -n "${CM_VERSION:-}" ]]; then
  PB "Set :CFBundleShortVersionString $CM_VERSION"
  PB "Set :CFBundleVersion $CM_VERSION"
fi
if [[ "${CM_RELEASE:-}" == 1 ]]; then
  PB "Delete :CMRepoPath"
else
  PB "Set :CMRepoPath '$PWD'"
fi

# Nested executables first, then the bundle (no --deep: it would re-sign with the wrong options).
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  sign=(codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
else
  sign=(codesign --force --sign - --timestamp=none)
fi
"${sign[@]}" --identifier "$LABEL" "$APP/Contents/MacOS/fand"
"${sign[@]}" --identifier com.moritzthiele.cgate.cli "$APP/Contents/MacOS/cgate"
"${sign[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
