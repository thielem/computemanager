#!/usr/bin/env bash
# Install fand as a root LaunchDaemon (INST-1). Idempotent: re-running rebuilds and reloads.
# Usage: sudo scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=com.moritzthiele.cgate.fand
DEST_DIR=/usr/local/libexec/computemanager
DEST_BIN=$DEST_DIR/fand
PLIST_SRC=packaging/launchd/$LABEL.plist
PLIST_DST=/Library/LaunchDaemons/$LABEL.plist

say() { echo "install: $*"; }

if [[ $EUID -ne 0 ]]; then
  echo "install: needs root. Run: sudo $0" >&2
  exit 1
fi
if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == root ]]; then
  echo "install: run via sudo from your user account (the build must not run as root)" >&2
  exit 1
fi

# A root daemon binary must not live under a path a non-root user can modify (binary swap).
for d in /usr/local /usr/local/libexec "$DEST_DIR"; do
  [[ -e "$d" ]] || continue  # created below as root:wheel 0755
  read -r uid perm < <(stat -f '%u %Lp' "$d")
  if [[ -L "$d" || "$uid" != 0 || $(( 8#$perm & 8#022 )) != 0 ]]; then
    echo "install: unsafe install dir $d (owner uid $uid, mode $perm, or symlink); needs root-owned, not group/other-writable." >&2
    echo "install: fix with: sudo chown root:wheel $d && sudo chmod go-w $d" >&2
    exit 1
  fi
done

say "building fand (release) as $SUDO_USER"
sudo -H -u "$SUDO_USER" scripts/swiftw build -c release --product fand
BIN_DIR=$(sudo -H -u "$SUDO_USER" scripts/swiftw build -c release --show-bin-path)
BUILT=$BIN_DIR/fand
[[ -x "$BUILT" ]] || { echo "install: build output missing: $BUILT" >&2; exit 1; }

say "ad-hoc signing $BUILT"
sudo -H -u "$SUDO_USER" codesign --force --sign - --identifier "$LABEL" "$BUILT"

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
install -o root -g wheel -m 0755 "$BUILT" "$DEST_BIN"
xattr -c "$DEST_BIN" 2>/dev/null || true

say "installing $PLIST_DST (root:wheel 0644)"
install -o root -g wheel -m 0644 "$PLIST_SRC" "$PLIST_DST"
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
  echo "install: could not load $LABEL. Try manually: sudo launchctl bootstrap system $PLIST_DST" >&2
  echo "install: then inspect: log show --last 2m --predicate 'process == \"launchd\"' | grep -i cgate" >&2
  exit 1
fi

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -S /var/run/computemanager/fand.sock ]] && break
  sleep 0.5
done
if [[ -S /var/run/computemanager/fand.sock ]]; then
  say "ok: fand running, socket /var/run/computemanager/fand.sock"
else
  say "WARNING: socket not up yet; check /var/log/computemanager-fand.log and: sudo launchctl print system/$LABEL"
fi
