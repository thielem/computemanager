#!/usr/bin/env bash
# Remove fand: stop the daemon (fans revert to Auto), force Auto once more, remove binary, plist,
# socket directory and log. Idempotent. Used by scripts/uninstall.sh and the Homebrew cask.
# Usage: sudo uninstall-fand.sh
set -euo pipefail

LABEL=com.moritzthiele.cgate.fand
DEST_DIR=/usr/local/libexec/computemanager
DEST_BIN=$DEST_DIR/fand
PLIST_DST=/Library/LaunchDaemons/$LABEL.plist
SOCK_DIR=/var/run/computemanager
LOG=/var/log/computemanager-fand.log

say() { echo "uninstall-fand: $*"; }

if [[ $EUID -ne 0 ]]; then
  echo "uninstall-fand: needs root. Run: sudo '$0'" >&2
  exit 1
fi

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  say "stopping daemon (SIGTERM → fans revert to Auto)"
  launchctl bootout "system/$LABEL" || true
else
  say "daemon not loaded"
fi

if [[ -x "$DEST_BIN" ]]; then
  say "forcing fans to Auto"
  "$DEST_BIN" --revert-auto || say "WARNING: --revert-auto failed; fans return to Auto at the latest on reboot"
fi

for f in "$PLIST_DST" "$DEST_BIN" "$LOG"; do
  if [[ -e "$f" ]]; then say "removing $f"; rm -f "$f"; fi
done
for d in "$DEST_DIR" "$SOCK_DIR"; do
  if [[ -d "$d" ]]; then say "removing $d"; rm -rf "$d"; fi
done
say "done"
