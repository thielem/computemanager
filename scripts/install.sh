#!/usr/bin/env bash
# Install fand as a root LaunchDaemon (INST-1). Idempotent: re-running rebuilds and reloads.
# Builds fand as SUDO_USER, signs it, then hands off to scripts/install-fand.sh (shared with the cask).
# Usage: sudo scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=com.moritzthiele.cgate.fand

if [[ $EUID -ne 0 ]]; then
  echo "install: needs root. Run: sudo $0" >&2
  exit 1
fi
if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == root ]]; then
  echo "install: run via sudo from your user account (the build must not run as root)" >&2
  exit 1
fi

scripts/install-fand.sh --check-dirs  # fail before building if the install dir is unsafe

echo "install: building fand (release) as $SUDO_USER"
sudo -H -u "$SUDO_USER" scripts/swiftw build -c release --product fand
BIN_DIR=$(sudo -H -u "$SUDO_USER" scripts/swiftw build -c release --show-bin-path)
BUILT=$BIN_DIR/fand
[[ -x "$BUILT" ]] || { echo "install: build output missing: $BUILT" >&2; exit 1; }

echo "install: ad-hoc signing $BUILT"
sudo -H -u "$SUDO_USER" codesign --force --sign - --identifier "$LABEL" "$BUILT"

exec scripts/install-fand.sh "$BUILT" "$PWD/packaging/launchd/$LABEL.plist"
