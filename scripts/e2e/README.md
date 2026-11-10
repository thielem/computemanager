# E2E harness (compute gate)

Runs against a headless gate host (`Sources/gatehost`, DEBUG-only, not a product) on
`/tmp/cm-e2e-<pid>.sock`. Nothing is installed; the real gate socket, `~/.claude` settings and
the calling Claude session are not touched (parent `CLAUDE_*` vars are stripped; cgate gets
`HOME`/`CFFIXED_USER_HOME` set to a temp dir, so the fallback log lands there).

| Script | What |
|---|---|
| `cli.sh` | A: busy/ticket/wait/claim, hook fixtures, walltime (77), hard stop (78, pgid empty), soft stop, noMore (76), per-job kill, host down (fail open + fallback log). ~1.5 min; `E2E_SLOW=1` adds ticket expiry (+2 min) |
| `claude.sh` | B: real `claude -p` (sonnet, ≤6 turns) with `--plugin-dir plugin/compute-gate`, `--setting-sources project`: B1 hook deny → `cgate run` → lease with session id; B2 noMore → "Compute gate off"; B3 pending stop notice → first tool call denied. `E2E_ONLY="B1"` to pick |

`E2E_SKIP_BUILD=1` skips the (locked) debug build. Logs (gatehost requests + status changes,
stream-json transcripts) stay in the temp dir printed at the end.

Manual driving:

```
.build/debug/gatehost serve --socket /tmp/cm-e2e-x.sock --slots 1 [--push]
.build/debug/gatehost ctl --socket /tmp/cm-e2e-x.sock status | setGate noMore | killJob <uuid>
COMPUTEMANAGER_GATE_SOCK=/tmp/cm-e2e-x.sock .build/debug/cgate status
```

Not covered: messaging-socket push (`--push`) into an idle interactive session; ticket wake-up
of a real agent via background-task completion; app UI; fans.
