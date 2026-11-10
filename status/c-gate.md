# c-gate status
## Done
- GateCore: pure `GateMachine` (slots, levels on/noMore/softStop/hardStop, leases + walltime soft→hard, reattach, reaper, FIFO tickets per (session, cwd) with ETA and 2 min holds, killJob, setSettings, meeting) + `GateService` (lock, 1 s tick, reaper, waitTicket long-poll, onChange on change only, messaging-socket push).
- `CommandMatcher`: heavy-command matching (heredocs skipped, harmless prefixes stripped; semantics in its doc comment and plugin README).
- cgate: `run` (own pgid, heartbeat, directives, reattach, signal forwarding, fail-open + fallback log), `wait`, `hook` (≤0.5 s, fail open; deny-with-redirect, never rewrites), `status`.
- Plugin `plugin/compute-gate` (plugin.json, hooks.json with one `"*"` PreToolUse entry, skill, README). Not installed.
- Tests: GateCoreTests (machine, service, matcher, messaging socket), cgateTests (run/wait/hook e2e against in-process GateService on /tmp/cm-test-*.sock, hard stop pgid kill, SIGKILL escalation, walltime with fake clock, reattach after restart, ungated).
## In progress
## Blocked
## Questions
## Contract-change requests
- (optional) Messaging token: server-side pushes send no `auth` line (M0b: auth optional on macOS). If Claude Code starts requiring it, add `messagingToken: String?` to `AcquireRequest` (never stored in `Lease`/status). No change needed now.
- (optional) `Lease.autoWrapped` and `HookDecision.wrap` are unused since K1 (always false / never produced; a `wrap` would render as no output). Could be removed from Shared.
- (optional) `GateStatus.heldSlot` is single; with H2 several slots can be held. Snapshot reports the first; per-ticket ETA of a held ticket = hold start. Proposed: add `heldSlots: [HeldSlot]` (keep `heldSlot` = first).
## Review triage
Round 1 (all accepted ones fixed with regression tests):
- H1 `cgate run`: after the child exits, a killed/interrupted run SIGKILLs its whole pgid (TERM-ignoring grandchildren).
- H2 one hold per free slot for the oldest queued tickets (each its own 2 min hold); a ticket first in queue is granted when a slot is free; fresh acquires busy only while all free slots are held.
- M1 `setGate(.on)` drops undelivered soft-stop notices. M2 `meeting` only on → noMore.
- M3 matcher skips heredoc bodies; strips `bash/sh/zsh` (script path; `-c` line), `timeout N`, `env`/`VAR=`, `uv run [--flags]`, `python[3] -m`, `npx`, `pnpm exec` (every layer tried).
- M4 SKILL: quote the whole line as one argument; `--` + one arg = shell line, several = argv (documented). L6 `isWrapped` only for a line that is exactly one cgate invocation.
- M5 + K2 machine tracks last heartbeat per job; reaper drops leases silent > 30 s (plus dead pid); the service SIGTERMs a reaped lease's live pgid, SIGKILL after killGrace. After system sleep (wall vs uptime gap > 5 s) all leases count as just seen, so sleep does not kill jobs.
- L1 `$SHELL` only if bash/zsh/sh, else /bin/bash; `cd` non-persistence documented. L3 signal handlers before spawn, SIGKILL escalation after killGrace, exit 128+signal. L4 raw deadlines in snapshots (held ETA = hold start) → no onChange per tick. L5 ended `cgate wait` poll counts as waiting for 1 s.
- Rejected: L2 (TTY foreground pgrp; not relevant under Claude Code).
- K1: no rewrite, deny-with-redirect (user decision). Hook never returns "allow"/`updatedInput`; heavy unwrapped Bash → deny "Compute gate: heavy command. Re-run as: cgate run --max <estimate> -- '<cmd>' with run_in_background: true"; busy/off reported by `cgate run`; notices still delivered once via deny; app unreachable → no output. Session for redirected runs via CLAUDE_CODE_SESSION_ID / ~/.claude/sessions fallback (tested).
