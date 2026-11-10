#!/usr/bin/env bash
# Scenario B: real headless Claude Code sessions (sonnet, ≤6 turns each) with the plugin from
# this worktree and debug cgate first on PATH, against a headless gate host.
# Needs a logged-in `claude`. Costs up to three small sonnet runs; pick with E2E_ONLY="B1 B3".
#   B1: agent runs scripts/check.sh directly → hook denies with cgate line → agent re-runs via
#       cgate run → lease with the session id → completes.
#   B2: gate noMore → agent's cgate run gets "Compute gate off" (exit 76).
#   B3: gate soft-stopped with a pending notice for the session → first tool call denied with
#       the notice (stand-in for the messaging-socket push, which headless can't show).
source "$(dirname "$0")/lib.sh"
build || exit 1
PROJ="$E2E_TMP/proj"
mkdir -p "$PROJ/scripts"
printf '#!/bin/sh\nsleep 5\necho ok\n' >"$PROJ/scripts/check.sh"
chmod +x "$PROJ/scripts/check.sh"

# Claude itself keeps the real HOME (auth); only parent-session vars are stripped. User
# settings/hooks are not loaded (--setting-sources project), so only this plugin's hook runs.
cc() {  # cc <session-id> <out.jsonl> <prompt>
  (cd "$PROJ" && env "${STRIP[@]}" COMPUTEMANAGER_GATE_SOCK="$SOCK" PATH="$BIN:$PATH" \
    claude -p "$3" --plugin-dir "$WT/plugin/compute-gate" --setting-sources project \
      --model sonnet --max-turns 6 --session-id "$1" --no-session-persistence \
      --output-format stream-json --verbose \
      --allowedTools "Bash(cgate:*)" "Bash(scripts/check.sh)" "Bash(./scripts/check.sh)" \
      </dev/null >"$2" 2>"$2.err")
}
checker() { uv run --no-project python "$WT/scripts/e2e/check_claude.py" "$@"; }
PROMPT='Run the project test script scripts/check.sh (exactly that command first) and report its output in one line. Follow any instructions you get from hooks or tools.'

ONLY="${E2E_ONLY:-B1 B2 B3}"
want() { [[ " $ONLY " == *" $1 "* ]]; }
start_host --slots 1

if want B1; then
  echo "== B1: hook deny → cgate run → lease → done"
  ctl setGate on 1 >/dev/null
  S=$(uuidgen | tr A-Z a-z)
  cc "$S" "$E2E_TMP/b1.jsonl" "$PROMPT"
  if checker b1 "$E2E_TMP/b1.jsonl" "$HOSTLOG" "$S"; then ok "B1"; else bad "B1"; fi
fi

if want B2; then
  echo "== B2: gate noMore → 'Compute gate off'"
  ctl setGate noMore >/dev/null
  S=$(uuidgen | tr A-Z a-z)
  cc "$S" "$E2E_TMP/b2.jsonl" "$PROMPT"
  if checker b2 "$E2E_TMP/b2.jsonl" "$HOSTLOG" "$S"; then ok "B2"; else bad "B2"; fi
fi

if want B3; then
  echo "== B3: pending soft-stop notice delivered via hook"
  S=$(uuidgen | tr A-Z a-z)
  ctl setGate on 1 >/dev/null
  iso cgate run --session "$S" --max 5m -- 'sleep 3' >/dev/null 2>&1 &
  J=$!
  sleep 1
  ctl setGate softStop >/dev/null   # queues a stop notice for S
  wait $J
  cc "$S" "$E2E_TMP/b3.jsonl" "$PROMPT"
  if checker b3 "$E2E_TMP/b3.jsonl" "$HOSTLOG" "$S"; then ok "B3"; else bad "B3"; fi
fi

finish
