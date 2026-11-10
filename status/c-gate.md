# c-gate status
## Done
- GateCore: pure `GateMachine` (slots, levels on/noMore/softStop/hardStop, leases + walltime soft→hard, reattach, reaper, FIFO tickets per (session, cwd) with ETA and 2 min holds, killJob, setSettings, meeting) + `GateService` (lock, 1 s tick, reaper, waitTicket long-poll, onChange on change only, messaging-socket push).
- `CommandMatcher`: auto-wrap matching (semantics in its doc comment and plugin README).
- cgate: `run` (own pgid, heartbeat, directives, reattach, signal forwarding, fail-open + fallback log), `wait`, `hook` (≤0.5 s, fail open), `status`.
- Plugin `plugin/compute-gate` (plugin.json, hooks.json with one `"*"` PreToolUse entry, skill, README). Not installed.
- Tests: GateCoreTests (machine, service, matcher, messaging socket), cgateTests (run/wait/hook e2e against in-process GateService on /tmp/cm-test-*.sock, hard stop pgid kill, SIGKILL escalation, walltime with fake clock, reattach after restart, ungated).
## In progress
## Blocked
## Questions
## Contract-change requests
- (optional) Messaging token: server-side pushes send no `auth` line (M0b: auth optional on macOS). If Claude Code starts requiring it, add `messagingToken: String?` to `AcquireRequest` (never stored in `Lease`/status). No change needed now.
- (optional) `autoWrapped` has no CLI flag; cgate sets it when `--session` is given (only the hook passes it). A hidden `--auto` flag would be cleaner.
## Review triage
