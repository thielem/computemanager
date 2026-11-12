#!/usr/bin/env bash
# Install fand as a root LaunchDaemon. Idempotent: re-running replaces the binary and reloads.
# Usage: sudo install-fand.sh [<fand-binary> <plist>]
# Without arguments (copy inside ComputeManager.app/Contents/Resources) it installs the bundle's
# own Contents/MacOS/fand and Contents/Resources/<label>.plist. Used by scripts/install.sh and
# the Homebrew cask; does not need SUDO_USER.
set -euo pipefail

LABEL=com.moritzthiele.cgate.fand
DEST_DIR=/usr/local/libexec/computemanager
DEST_BIN=$DEST_DIR/fand
PLIST_DST=/Library/LaunchDaemons/$LABEL.plist
SOCK=/var/run/computemanager/fand.sock

say() { echo "install-fand: $*"; }
die() { echo "install-fand: $*" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
SRC_BIN=${1:-$HERE/../MacOS/fand}
SRC_PLIST=${2:-$HERE/$LABEL.plist}

[[ $EUID -eq 0 ]] || die "needs root. Run: sudo '$0'"
[[ -x "$SRC_BIN" && -f "$SRC_PLIST" ]] \
  || die "missing $SRC_BIN or $SRC_PLIST. Usage: sudo $0 [<fand-binary> <plist>]"

# A root daemon binary must not live under a path a non-root user can modify (binary swap).
for d in /usr/local /usr/local/libexec "$DEST_DIR"; do
  [[ -e "$d" ]] || continue  # created below as root:wheel 0755
  read -r uid perm < <(stat -f '%u %Lp' "$d")
  if [[ -L "$d" || "$uid" != 0 || $(( 8#$perm & 8#022 )) != 0 ]]; then
    echo "install-fand: unsafe install dir $d (owner uid $uid, mode $perm, or symlink); needs root-owned, not group/other-writable." >&2
    die "fix with: sudo chown root:wheel $d && sudo chmod go-w $d"
  fi
done

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  say "stopping running daemon (fans revert to Auto)"
  launchctl bootout "system/$LABEL" || true
  # bootout is async: bootstrapping before the service is fully gone fails with "Input/output error"
  for _ in $(seq 1 40); do
    launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    sleep 0.25
  done
fi

say "installing $DEST_BIN (root:wheel 0755)"
install -d -o root -g wheel -m 0755 "$DEST_DIR"
install -o root -g wheel -m 0755 "$SRC_BIN" "$DEST_BIN"
xattr -c "$DEST_BIN" 2>/dev/null || true  # incl. com.apple.quarantine from a download

say "installing $PLIST_DST (root:wheel 0644)"
install -o root -g wheel -m 0644 "$SRC_PLIST" "$PLIST_DST"
xattr -c "$PLIST_DST" 2>/dev/null || true

say "loading $LABEL"
launchctl enable "system/$LABEL"
loaded=0
for attempt in 1 2 3; do
  if launchctl bootstrap system "$PLIST_DST"; then loaded=1; break; fi
  say "bootstrap failed (attempt $attempt/3), retrying"
  sleep 1
done
if [[ $loaded -eq 0 ]]; then
  say "retrying via enable + kickstart"
  launchctl enable "system/$LABEL" || true
  if launchctl kickstart -k "system/$LABEL"; then loaded=1; fi
fi
if [[ $loaded -eq 0 ]]; then
  echo "install-fand: could not load $LABEL. Try manually: sudo launchctl bootstrap system $PLIST_DST" >&2
  die "then inspect: log show --last 2m --predicate 'process == \"launchd\"' | grep -i cgate"
fi

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -S $SOCK ]] && break
  sleep 0.5
done
if [[ -S $SOCK ]]; then
  say "ok: fand running, socket $SOCK"
else
  say "WARNING: socket not up yet; check /var/log/computemanager-fand.log and: sudo launchctl print system/$LABEL"
fi
