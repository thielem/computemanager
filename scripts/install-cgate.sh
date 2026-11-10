#!/usr/bin/env bash
# Build release cgate, ad-hoc sign it and install it to ~/.local/bin/cgate (idempotent).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> building cgate (release)"
scripts/swiftw build -c release --product cgate -q
BIN="$(scripts/swiftw build -c release --show-bin-path)/cgate"

DEST="$HOME/.local/bin/cgate"
echo "==> installing $DEST"
mkdir -p "$(dirname "$DEST")"
cp -f "$BIN" "$DEST.tmp"
echo "==> ad-hoc signing"
codesign --force --sign - --timestamp=none "$DEST.tmp"
mv -f "$DEST.tmp" "$DEST"
codesign --verify "$DEST"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "note: ~/.local/bin is not on PATH" ;;
esac
echo "==> done: $DEST"
