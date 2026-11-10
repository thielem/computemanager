# Sourced by scripts/e2e/*.sh. Headless gate host + isolated env for cgate.
# Never touches the real gate socket, ~/.claude or the user's Claude Code session:
# the parent session's CLAUDE_* vars are stripped, HOME + CFFIXED_USER_HOME (Foundation ignores
# HOME) point to a temp dir, so the fallback log lands there.
set -uo pipefail
WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$WT/.build/debug"
E2E_TMP="$(mktemp -d -t cm-e2e)"
SOCK="/tmp/cm-e2e-$$.sock"
HOSTLOG="$E2E_TMP/gatehost.log"
E2E_HOME="$E2E_TMP/home"
mkdir -p "$E2E_HOME"
PASS=0 FAIL=0
HOST_PID=""

# Env for everything under test: no parent-session leakage, our socket, debug cgate first.
STRIP=(-u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ID
       -u CLAUDE_PID -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_CHILD_SESSION
       -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_CODE_EXECPATH -u AI_AGENT -u CLAUDE_EFFORT)
iso() { env "${STRIP[@]}" HOME="$E2E_HOME" CFFIXED_USER_HOME="$E2E_HOME" COMPUTEMANAGER_GATE_SOCK="$SOCK" PATH="$BIN:$PATH" "$@"; }

ok()   { PASS=$((PASS + 1)); echo "  PASS $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has()  { grep -qE -- "$2" "$1"; }

start_host() {  # start_host [gatehost serve options…]
  # Not via iso(): a backgrounded function is a subshell, so $! would not be gatehost.
  env "${STRIP[@]}" HOME="$E2E_HOME" CFFIXED_USER_HOME="$E2E_HOME" \
    "$BIN/gatehost" serve --socket "$SOCK" "$@" >>"$HOSTLOG" 2>&1 &
  HOST_PID=$!
  for _ in $(seq 50); do [[ -S "$SOCK" ]] && return 0; sleep 0.1; done
  echo "gatehost did not start"; cat "$HOSTLOG"; exit 1
}
stop_host() {
  [[ -n "$HOST_PID" ]] && kill "$HOST_PID" 2>/dev/null && wait "$HOST_PID" 2>/dev/null
  HOST_PID=""
  rm -f "$SOCK"
}
ctl() { iso "$BIN/gatehost" ctl --socket "$SOCK" "$@"; }

# Lease field of the first lease of a session from `status` JSON (uv-managed python, stdlib only).
lease_field() {  # lease_field <session> <field>
  ctl status | uv run --no-project python -c '
import json,sys
s=json.load(sys.stdin)
for l in s["leases"]:
    if l["sessionId"]==sys.argv[1]: print(l.get(sys.argv[2],"")); break' "$1" "$2"
}

finish() {
  stop_host
  echo "== $PASS passed, $FAIL failed (logs: $E2E_TMP)"
  [[ $FAIL -eq 0 ]]
}
trap 'stop_host' EXIT

build() {
  [[ "${E2E_SKIP_BUILD:-}" == 1 ]] && return
  "$WT/scripts/swiftw" build --product cgate -q && "$WT/scripts/swiftw" build --product gatehost -q
}
