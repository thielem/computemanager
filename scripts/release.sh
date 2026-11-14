#!/usr/bin/env bash
# Build, sign, (notarize), zip a release and render the Homebrew cask.
# Usage: scripts/release.sh <version>
# Env: SIGN_IDENTITY  "Developer ID Application: …" (unset → ad-hoc, local testing only)
#      NOTARY_PROFILE notarytool keychain profile    (unset → not notarized)
# Never publishes: scripts/publish.sh does that. See docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

GH_OWNER=thielem   # GitHub owner of source repo + tap; the only place to change it (fills @GH_OWNER@ in packaging/homebrew/compute-manager.rb.in)

VERSION=${1:?usage: scripts/release.sh <version>  (e.g. 0.1.0)}
[[ $VERSION =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "release: bad version '$VERSION'" >&2; exit 1; }
[[ -z "${NOTARY_PROFILE:-}" || -n "${SIGN_IDENTITY:-}" ]] || { echo "release: NOTARY_PROFILE needs SIGN_IDENTITY" >&2; exit 1; }

source scripts/build-lock.sh
cm_lock  # one build at a time; bundle.sh/swiftw below share this lock

APP=dist/ComputeManager.app
ZIP=dist/ComputeManager-$VERSION.zip
CASK=packaging/homebrew/Casks/compute-manager.rb
mkdir -p dist
rm -rf "$APP" "$ZIP"

echo "==> building $APP $VERSION"
CM_APP=$APP CM_VERSION=$VERSION CM_RELEASE=1 scripts/bundle.sh >/dev/null

for b in ComputeManager fand cgate; do
  archs=$(lipo -archs "$APP/Contents/MacOS/$b")
  [[ $archs == arm64 ]] || { echo "release: $b is '$archs', expected arm64" >&2; exit 1; }
done
cm_unlock  # build done; don't hold the project build lock through notarization

ditto -c -k --keepParent "$APP" "$ZIP"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> notarizing"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"  # re-zip with the stapled ticket
fi

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -e "s/@VERSION@/$VERSION/g" -e "s/@SHA256@/$SHA/g" -e "s#@GH_OWNER@#$GH_OWNER#g" \
  packaging/homebrew/compute-manager.rb.in > "$CASK"

echo "==> $ZIP"
echo "    sha256 $SHA"
echo "    cask   $CASK"
if [[ -z "${SIGN_IDENTITY:-}" || -z "${NOTARY_PROFILE:-}" ]]; then
  cat >&2 <<WARN

*** WARNING: not Developer ID signed + notarized (SIGN_IDENTITY='${SIGN_IDENTITY:-}', NOTARY_PROFILE='${NOTARY_PROFILE:-}').
*** Local testing only. Do NOT publish this zip: Gatekeeper blocks it on other Macs.
*** See docs/RELEASING.md.

WARN
fi
echo "Next: commit $CASK, then scripts/publish.sh $VERSION --dry-run, then without --dry-run."
