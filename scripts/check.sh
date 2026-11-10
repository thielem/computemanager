#!/usr/bin/env bash
# Build all targets and run all tests. Fail fast, quiet output (errors/failures only).
# Holds the project-wide build lock (scripts/build-lock.sh) for the whole run.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/build-lock.sh
cm_lock

CM_LOG=$(mktemp -t cm-check)

run() {
  local name=$1; shift
  if ! "$@" >"$CM_LOG" 2>&1; then
    sed $'s/\x1b\\[[0-9;]*m//g' "$CM_LOG" | grep -E "error:|✘|FAIL|failed|Fatal" | grep -v "^Failed frontend" \
      | head -40 >&2 || tail -60 "$CM_LOG" >&2
    echo "check.sh: $name FAILED" >&2
    exit 1
  fi
}

run "build" swift build --build-tests -q
run "test" swift test --skip-build -q
grep -E "Test run with|Executed .* tests" "$CM_LOG" || true
echo "check.sh: ok"
