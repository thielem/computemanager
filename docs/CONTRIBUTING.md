# Contributing

Design and protocol details: [design.md](design.md).

## Swift
- Swift 6 language mode, SwiftPM only (no Xcode project). macOS 14+.
- Value types for data, `Sendable` everywhere; no `@unchecked Sendable` without a lock and a comment.
- Small files, one concern each. Prefer `guard` + early exit. No force unwraps outside tests (except provably safe).
- No third-party dependencies.
- Blocking I/O only on dedicated threads (see `Sources/Shared/UnixSocket.swift`), never on the Swift cooperative pool or main actor.
- Durations: `TimeInterval` seconds; JSON fields suffixed `Seconds`. Dates on the wire: seconds since 1970.
- `Sources/Shared` is the wire contract between app, fand and cgate. Change both sides together.

## Logging and privacy
- Log only what is needed to debug: op names, job ids, ticket ids, exit codes, pids.
- Never log full commands, env, hook stdin, or file contents beyond what the UI already shows. Truncate commands (≤ 60 chars) when logging is unavoidable.
- No PII, no secrets, no tokens (e.g. `CLAUDE_CODE_MESSAGING_TOKEN`).

## Tests
- Required for all logic: state machines (gate levels, leases, walltime), ETA, tickets/holds, fan curve + hysteresis, watchdog, hook decisions, CLI parsing, codecs.
- Use swift-testing (`import Testing`). Inject clocks (`now: Date`) instead of sleeping.
- Tests must not touch the SMC, real sockets under `/var/run`, or `~/Library`. Use short temp paths (`/tmp/cm-test-*.sock`; `sun_path` max 104 bytes) or env overrides (`COMPUTEMANAGER_GATE_SOCK`, `COMPUTEMANAGER_FAND_SOCK`).
- `scripts/check.sh` (build all targets + all tests) must be green before every commit. Use `scripts/swiftw <swift args>` instead of bare `swift build`/`swift test`; both take the project build lock (one build/test run at a time).

## Safety
- No SMC writes outside fand, and fand writes only `Ftst` (if present), `F{n}Md`, `F{n}Tg` (target clamped to min/max).
- fand stays minimal: no gate logic in the root daemon, no raw SMC key writes over IPC, requests only from the console user's UID.
- Fans must revert to Auto on app quit/crash, 10 s without heartbeat, fand start/stop, and uninstall.
