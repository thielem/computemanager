# Conventions

## Swift
- Swift 6 language mode, SwiftPM only (no Xcode project). macOS 14+.
- Value types for data, `Sendable` everywhere; no `@unchecked Sendable` without a lock and a comment.
- Small files, one concern each. Prefer `guard` + early exit. No force unwraps outside tests (except provably safe).
- No third-party dependencies without orchestrator approval.
- Blocking I/O only on dedicated threads (see `Shared/UnixSocket.swift`), never on the Swift cooperative pool or main actor.
- Durations: `TimeInterval` seconds; JSON fields suffixed `Seconds`. Dates on the wire: seconds since 1970.

## Logging and privacy
- Log only what is needed to debug: op names, job ids, ticket ids, exit codes, pids.
- Never log full commands, env, hook stdin, or file contents beyond what the UI already shows. Truncate commands (≤ 60 chars) when logging is unavoidable.
- No PII, no secrets, no tokens (e.g. `CLAUDE_CODE_MESSAGING_TOKEN`).

## Tests
- Required for all logic: state machines (gate levels, leases, walltime), ETA, tickets/holds, fan curve + hysteresis, watchdog, hook decisions, CLI parsing, codecs.
- Use swift-testing (`import Testing`). Inject clocks (`now: Date`) instead of sleeping.
- Tests must not touch the SMC, real sockets under `/var/run`, or `~/Library`. Use short temp paths (`/tmp/cm-test-*.sock`; `sun_path` max 104 bytes) or env overrides (`COMPUTEMANAGER_GATE_SOCK`, `COMPUTEMANAGER_FAND_SOCK`).

## Contracts
- `Sources/Shared` (IPC types, envelope, socket helper, exit codes, messages, defaults, paths) is owned by the orchestrator and frozen.
- Do not edit it in a package branch. File a contract-change request in your status file (what, why, exact proposed diff). Additive helpers you need privately go in your own target.

## Branches and commits
- Work only on your sub-branch `main--<pkg>` in your own worktree (`../computemanager-wt/<pkg>`). Never write to `main` or any other branch; never push; never force.
- Commit after each meaningful step. Message: imperative summary line; body optional; end with a blank line and
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Checks
- `scripts/check.sh` = build all targets + all tests; must be green before every commit you report.
- Within this project at most 1 build/test run at a time, across all worktrees. Always build/test via
  `scripts/check.sh` or `scripts/swiftw <swift args>` (e.g. `scripts/swiftw test --filter GateCoreTests`).
  Both take the lock `/tmp/computemanager-build.lock` (mkdir; holder PID inside; 2 s wait loop; stale lock
  of a dead PID is removed; released on exit). Never run bare `swift build`/`swift test`.
- Other projects' builds are ignored. Each worktree has its own `.build`, that's fine.

## Safety
- No SMC writes outside fand, and fand writes only `Ftst`, `F{n}Md`, `F{n}Tg` (target clamped to min/max).
- No sudo, nothing installed system-wide by agents. Install steps go to TODO.md for the user.

## Python
- If ever needed: uv only (`uv run`, `uv add`, inline script metadata). Never pip/conda/poetry.

## GateService UI API
App (B) creates GateService with persisted settings/level, subscribes via onChange, mutates only via handle(...).

## Status file
`status/<pkg>.md`, updated at each milestone, with these sections:

```
# <pkg> status
## Done
## In progress
## Blocked
## Questions
## Contract-change requests
## Review triage
```
