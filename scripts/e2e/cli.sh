#!/usr/bin/env bash
# Scenario A: CLI-level E2E (no Claude). Takes ~1.5 min (walltime grace is a fixed 60 s);
# E2E_SLOW=1 adds ticket expiry (+2 min, hold is a fixed 2 min).
source "$(dirname "$0")/lib.sh"
build || exit 1
T=$E2E_TMP
echo "== A: cgate CLI against headless gate host (slots 1), socket $SOCK"
start_host --slots 1

echo "-- busy + ticket + wait + claim"
iso cgate run --session e2e-a --max 20s -- 'sleep 6; echo a-done' >"$T/a.out" 2>"$T/a.err" &
A=$!
sleep 1
iso cgate run --session e2e-b --max 1m -- 'echo b' >"$T/b.out" 2>"$T/b.err"; rc=$?
check "busy exit 75 (got $rc)" test $rc -eq 75
check "busy message has ticket, position, ETA, wait hint: $(cat "$T/b.err")" \
  has "$T/b.err" '^compute busy: ticket [^,]+, position 1, next slot by ~[0-9]{2}:[0-9]{2} \(latest\), then held for you .*Start `cgate wait --ticket'
TICKET=$(sed -nE 's/^compute busy: ticket ([^,]+),.*/\1/p' "$T/b.err")
start=$(date +%s)
iso cgate wait --ticket "$TICKET" >"$T/w.out" 2>"$T/w.err"; rc=$?
waited=$(( $(date +%s) - start ))
wait $A; arc=$?
check "job A completed normally (rc $arc)" test $arc -eq 0
check "wait exit 0 after slot freed (${waited}s): $(cat "$T/w.err")" \
  bash -c "[[ $rc -eq 0 && $waited -ge 3 ]] && grep -q 'Slot ready for ticket $TICKET — claim within' '$T/w.err'"
iso cgate run --session e2e-b --ticket "$TICKET" --max 1m -- 'echo claimed' >"$T/c.out" 2>"$T/c.err"; rc=$?
check "run --ticket claims held slot (rc $rc, out $(cat "$T/c.out"))" bash -c "[[ $rc -eq 0 ]] && grep -q claimed '$T/c.out'"

echo "-- hook fixtures (gate up)"
hook() { printf '%s' "$1" | iso cgate hook; }
J_HEAVY='{"session_id":"e2e-h1","cwd":"/tmp/proj","tool_name":"Bash","tool_input":{"command":"scripts/check.sh"}}'
J_WRAP='{"session_id":"e2e-h1","cwd":"/tmp/proj","tool_name":"Bash","tool_input":{"command":"cgate run --max 5m -- '"'"'scripts/check.sh'"'"'"}}'
J_LIGHT='{"session_id":"e2e-h1","cwd":"/tmp/proj","tool_name":"Bash","tool_input":{"command":"ls -la"}}'
hook "$J_HEAVY" >"$T/h1.out"
check "heavy unwrapped → deny with copyable cgate line: $(cat "$T/h1.out")" \
  bash -c "grep -q '\"permissionDecision\":\"deny\"' '$T/h1.out' && grep -q \"cgate run --max\" '$T/h1.out' && grep -q 'scripts/check.sh' '$T/h1.out'"
check "wrapped → no output" test -z "$(hook "$J_WRAP")"
check "light command → no output" test -z "$(hook "$J_LIGHT")"

echo "-- walltime: notice at max, kill after 60 s grace (exit 77)"
iso cgate run --session e2e-w --max 2s -- 'sleep 300' >"$T/wt.out" 2>"$T/wt.err" &
W=$!
sleep 5
check "walltime notice printed by cgate: $(head -1 "$T/wt.err")" has "$T/wt.err" 'max runtime \(2s\) of'
out=$(hook '{"session_id":"e2e-w","cwd":"/tmp","tool_name":"Read","tool_input":{}}')
check "walltime notice via hook → deny: ${out:0:140}" grep -q 'max runtime (2s) of' <<<"$out"
check "notice delivered only once" test -z "$(hook '{"session_id":"e2e-w","cwd":"/tmp","tool_name":"Read","tool_input":{}}')"
check "process still running during grace" kill -0 $W
start=$(date +%s); wait $W; rc=$?; took=$(( $(date +%s) - start + 5 ))
check "walltime kill exit 77 after ~62 s (rc $rc, ${took}s): $(tail -1 "$T/wt.err")" \
  bash -c "[[ $rc -eq 77 && $took -ge 58 && $took -le 80 ]] && grep -q 'killed: exceeded declared max runtime (2s)' '$T/wt.err'"

echo "-- hard stop kills process group (exit 78)"
ctl setGate on 2 >/dev/null
iso cgate run --session e2e-hs --max 5m -- 'sleep 301 & sleep 302; wait' >"$T/hs.out" 2>"$T/hs.err" &
H=$!
sleep 3
PG=$(lease_field e2e-hs pgid)
check "lease registered with pgid ($PG)" test -n "$PG"
ctl setGate hardStop >/dev/null
start=$(date +%s); wait $H; rc=$?; took=$(( $(date +%s) - start ))
check "hard stop exit 78 within ~10 s (rc $rc, ${took}s): $(cat "$T/hs.err")" \
  bash -c "[[ $rc -eq 78 && $took -le 12 ]] && grep -q 'killed by user: hard stop' '$T/hs.err'"
check "no survivors in pgid $PG (incl. background grandchild)" bash -c "! pgrep -g $PG >/dev/null"
out=$(hook '{"session_id":"e2e-hs","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}')
check "hard-stop notice via hook: ${out:0:120}" grep -q 'hard-stopped' <<<"$out"

echo "-- soft stop: notice only, process keeps running"
ctl setGate on 2 >/dev/null
iso cgate run --session e2e-ss --max 5m -- 'sleep 6; echo soft-survived' >"$T/ss.out" 2>"$T/ss.err" &
S=$!
sleep 1.5
ctl setGate softStop >/dev/null
wait $S; rc=$?
check "soft stop: cgate printed notice: $(head -1 "$T/ss.err")" has "$T/ss.err" 'user needs the machine'
check "soft stop: process finished normally (rc $rc)" bash -c "[[ $rc -eq 0 ]] && grep -q soft-survived '$T/ss.out'"
out=$(hook '{"session_id":"e2e-ss","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}')
check "soft-stop notice via hook" grep -q 'user needs the machine' <<<"$out"

echo "-- noMore: new runs denied (76), running finishes"
ctl setGate on 2 >/dev/null
iso cgate run --session e2e-nm --max 5m -- 'sleep 4; echo nm-done' >"$T/nm.out" 2>"$T/nm.err" &
N=$!
sleep 1.5
ctl setGate noMore >/dev/null
iso cgate run --session e2e-nm2 --max 1m -- 'echo nope' >"$T/nm2.out" 2>"$T/nm2.err"; rc=$?
check "noMore: new run exit 76 (rc $rc): $(cat "$T/nm2.err")" \
  bash -c "[[ $rc -eq 76 ]] && grep -q 'Compute gate off' '$T/nm2.err' && ! grep -q nope '$T/nm2.out'"
wait $N; rc=$?
check "noMore: running job finished (rc $rc)" bash -c "[[ $rc -eq 0 ]] && grep -q nm-done '$T/nm.out'"

echo "-- per-job kill (UI kill) → exit 78"
ctl setGate on 2 >/dev/null
iso cgate run --session e2e-k --max 5m -- 'sleep 300' >"$T/k.out" 2>"$T/k.err" &
K=$!
sleep 2.5
ctl killJob "$(lease_field e2e-k jobId)" >/dev/null
wait $K; rc=$?
check "killJob exit 78 (rc $rc)" test $rc -eq 78

if [[ "${E2E_SLOW:-}" == 1 ]]; then
  echo "-- ticket expiry: held slot unclaimed for 2 min → wait/run --ticket exit 79 (E2E_SLOW)"
  ctl setGate on 1 >/dev/null
  iso cgate run --session e2e-x1 --max 1m -- 'sleep 3' >/dev/null 2>&1 &
  X=$!
  sleep 1
  iso cgate run --session e2e-x2 --max 1m -- 'echo x' >/dev/null 2>"$T/x.err"
  XT=$(sed -nE 's/^compute busy: ticket ([^,]+),.*/\1/p' "$T/x.err")
  wait $X
  sleep 125
  iso cgate run --session e2e-x2 --ticket "$XT" --max 1m -- 'echo late' >/dev/null 2>"$T/x2.err"; rc=$?
  check "unclaimed ticket $XT expired → exit 79 (rc $rc): $(cat "$T/x2.err")" \
    bash -c "[[ $rc -eq 79 ]] && grep -q 'ticket $XT expired' '$T/x2.err'"
  iso cgate run --session e2e-x3 --max 1m -- 'echo free' >"$T/x3.out" 2>&1; rc=$?
  check "slot free again after expiry (rc $rc)" test $rc -eq 0
fi

echo "-- gate host down: fail open"
stop_host
start=$(date +%s)
iso cgate run --session e2e-down --max 1m -- 'echo ungated-ran' >"$T/d.out" 2>"$T/d.err"; rc=$?
FB="$E2E_HOME/Library/Logs/ComputeManager/cgate-fallback.log"
check "host down: run ungated (rc $rc)" bash -c "[[ $rc -eq 0 ]] && grep -q ungated-ran '$T/d.out'"
check "host down: fallback log line: $(tail -1 "$FB" 2>/dev/null)" has "$FB" 'ungated session=e2e-down .*cmd=echo ungated-ran'
t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
out=$(hook "$J_HEAVY")
ms=$(perl -MTime::HiRes=time -e "printf '%d', (time - $t0) * 1000")
check "host down: hook → no output, fast (${ms} ms)" bash -c "[[ -z '$out' && $ms -lt 1000 ]]"

finish
