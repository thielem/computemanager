#!/usr/bin/env bash
# Publish a release built by scripts/release.sh: tag + push, GitHub release, tap commit + push.
# Usage: scripts/publish.sh <version> [--dry-run] [--yes]
# Env: TAP_DIR  local checkout of the tap repo (default ../homebrew-tap relative to repo root)
# All preflights run before any write; refuses ad-hoc / unnotarized builds. See docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "publish: $*" >&2; exit 1; }

VERSION='' DRY=0 YES=0
for a in "$@"; do
  case $a in
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    -*) die "unknown flag '$a'" ;;
    *) [[ -z $VERSION ]] || die "unexpected argument '$a'"; VERSION=$a ;;
  esac
done
[[ -n $VERSION ]] || die "usage: scripts/publish.sh <version> [--dry-run] [--yes]"
[[ $VERSION =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "bad version '$VERSION'"

# GH_OWNER is defined once, in release.sh.
GH_OWNER=$(sed -n 's/^GH_OWNER=\([^ #]*\).*/\1/p' scripts/release.sh)
[[ -n $GH_OWNER ]] || die "could not read GH_OWNER from scripts/release.sh"
SRC_REPO=$GH_OWNER/computemanager
TAP_REPO=$GH_OWNER/homebrew-tap
TAP_DIR=${TAP_DIR:-../homebrew-tap}

TAG=v$VERSION
ZIP=dist/ComputeManager-$VERSION.zip
CASK=packaging/homebrew/Casks/compute-manager.rb
TAP_CASK=Casks/compute-manager.rb

# Runs a write, or just prints it with --dry-run.
run() {
  printf '+'; printf ' %q' "$@"; echo
  (( DRY )) || "$@"
}

# origin of repo $1 must be github.com/$2
check_origin() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || die "$1: no 'origin' remote"
  [[ $url =~ github\.com[:/]$2(\.git)?/?$ ]] || die "$1: origin is '$url', expected github.com/$2"
}

echo "==> build: $ZIP"
[[ -f $ZIP ]] || die "$ZIP not found; run scripts/release.sh $VERSION first"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
APP=$TMP/ComputeManager.app
[[ -d $APP ]] || die "$ZIP does not contain ComputeManager.app"
codesign --verify --deep --strict "$APP" 2>"$TMP/cs.err" \
  || die "codesign --verify failed: $(cat "$TMP/cs.err")"
[[ $(codesign -dvv "$APP" 2>&1) == *$'\n'"Authority=Developer ID Application:"* ]] \
  || die "app is not signed with a Developer ID (ad-hoc build?). Rebuild with SIGN_IDENTITY + NOTARY_PROFILE set; see docs/RELEASING.md"
spctl_out=$(spctl -a -vv -t exec "$APP" 2>&1) && [[ $spctl_out == *"source=Notarized Developer ID"* ]] \
  || die "Gatekeeper rejects the app (not notarized?):"$'\n'"$spctl_out"
xcrun stapler validate "$APP" >/dev/null 2>&1 \
  || die "no stapled notarization ticket (xcrun stapler validate failed)"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
grep -q "^  version \"$VERSION\"$" "$CASK" || die "$CASK version is not $VERSION; re-run scripts/release.sh $VERSION"
grep -q "^  sha256 \"$SHA\"$" "$CASK" || die "$CASK sha256 does not match $ZIP; re-run scripts/release.sh $VERSION"
ASSET_URL=$(sed -n 's/^  url "\(.*\)"$/\1/p' "$CASK")
ASSET_URL=${ASSET_URL//\#\{version\}/$VERSION}
[[ $ASSET_URL == "https://github.com/$SRC_REPO/releases/download/$TAG/ComputeManager-$VERSION.zip" ]] \
  || die "unexpected cask url '$ASSET_URL'"

echo "==> source repo"
check_origin . "$SRC_REPO"
[[ $(git branch --show-current) == main ]] || die "not on main"
# The rendered cask (version + sha256 checked above) may be uncommitted: we commit it. Nothing else may.
other=$(git status --porcelain -- . ":(exclude)$CASK")
[[ -z $other ]] || die "working tree not clean (only $CASK may be uncommitted):"$'\n'"$other"
COMMIT_CASK=0
[[ -z $(git status --porcelain -- "$CASK") ]] || COMMIT_CASK=1
git fetch -q origin main
git merge-base --is-ancestor origin/main HEAD || die "main is behind/diverged from origin/main; pull first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists locally"
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null; then die "tag $TAG already exists on origin"; fi
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"

echo "==> tap: $TAP_DIR"
[[ -d $TAP_DIR ]] || die "TAP_DIR '$TAP_DIR' not found (gh repo clone $TAP_REPO $TAP_DIR, or set TAP_DIR)"
git -C "$TAP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$TAP_DIR is not a git repo"
check_origin "$TAP_DIR" "$TAP_REPO"
[[ -z $(git -C "$TAP_DIR" status --porcelain) ]] || die "$TAP_DIR: working tree not clean"
run git -C "$TAP_DIR" pull -q --ff-only

STEP0=''
(( ! COMMIT_CASK )) || STEP0="  0. commit $CASK as \"compute-manager $VERSION\" on main"$'\n'
cat <<PLAN

Will publish ComputeManager $VERSION (sha256 $SHA):
${STEP0}  1. tag $TAG, push main + $TAG to $SRC_REPO
  2. gh release $TAG with $ZIP
  3. commit "compute-manager $VERSION" in $TAP_DIR ($TAP_REPO) and push
PLAN
if [[ $(gh repo view "$SRC_REPO" --json visibility -q .visibility 2>/dev/null) == PRIVATE ]]; then
  echo "  Note: $SRC_REPO is PRIVATE; brew users can't download the release until it is public."
fi
if (( ! DRY && ! YES )); then
  read -r -p "Proceed? [y/N] " ans
  [[ $ans == [yY]* ]] || die "aborted"
fi

echo "==> publishing"
if (( COMMIT_CASK )); then
  run git add "$CASK"
  run git commit -q -m "compute-manager $VERSION" -- "$CASK"
fi
run git tag -a "$TAG" -m "$TAG"
run git push origin main "$TAG"
run gh release create "$TAG" "$ZIP" --repo "$SRC_REPO" --title "$TAG" --generate-notes --verify-tag

run mkdir -p "$TAP_DIR/Casks"
run cp "$CASK" "$TAP_DIR/$TAP_CASK"
run git -C "$TAP_DIR" add "$TAP_CASK"
if (( DRY )) || ! git -C "$TAP_DIR" diff --cached --quiet; then
  run git -C "$TAP_DIR" commit -q -m "compute-manager $VERSION"
  run git -C "$TAP_DIR" push -q
else
  echo "tap cask unchanged, nothing to commit"
fi

echo "==> post-check"
if (( DRY )); then
  echo "+ curl -fsIL -o /dev/null $ASSET_URL"
else
  if curl -fsIL --retry 5 --retry-delay 3 -o /dev/null "$ASSET_URL"; then
    echo "asset OK: $ASSET_URL"
  else
    echo "WARNING: release asset not reachable anonymously. Expected while $SRC_REPO is private;" >&2
    echo "         make it public (gh repo edit $SRC_REPO --visibility public), then re-check:" >&2
    echo "         curl -fsIL -o /dev/null $ASSET_URL" >&2
  fi
fi
cat <<NEXT

Done$( (( DRY )) && echo " (dry run, nothing written)"). Next:
  brew update && brew install --cask $GH_OWNER/tap/compute-manager   # or: brew upgrade --cask compute-manager
  brew audit --cask --online $GH_OWNER/tap/compute-manager
NEXT
