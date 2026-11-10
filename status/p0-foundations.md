# p0-foundations status

## Done
- Env check: Swift 6.4.2, Xcode 27.2 (full Xcode, macOS 27.2 SDK), uv 0.12.21, pnpm 11.10.0 (via corepack).
- PLAN.md: O6/O7 resolved (fan control must, no read-only fallback; plugin `compute-gate`); TODO #7 done.
- SwiftPM skeleton: Shared, GateCore (libs); ComputeManager (MenuBarExtra), fand, cgate (executables); tests for Shared/GateCore/cgate.
- Shared contracts: envelope + codecs, fand protocol, gate protocol, gate model, cgate exit codes/messages, durations, defaults, paths, Unix socket NDJSON client/server with tests.
- scripts/check.sh + scripts/swiftw under project-wide build lock (/tmp/computemanager-build.lock), CONVENTIONS.md.
- PLAN.md: M0 findings recorded (no Ftst key → optional; F{n}Md ui8 + F{n}Tg flt; Mn 2317 / Mx 6800; messaging socket format; process tree).
- Shared: ClaudeMessaging env names. check.sh green: 19 tests.
- Review fixes (findings on 151c87c), see Review triage. check.sh green: 34 tests.

## In progress
- none

## Blocked
- none

## Questions
- none

## Contract-change requests
- n/a (orchestrator-owned package)

## Review triage
Review of 151c87c. All accepted unless noted:
1. Accepted: `AcquireRequest.reattach {jobId, startedAt}`; server always grants, keeps jobId + deadline; cgate `unknownJob` behaviour documented (`Reattach`).
2. Accepted: GateRequest `killJob(KillJobRequest)` and `setSettings(GateSettings)` → `GateStatus`; `GateSettings.slots` added; UI calls ops via `GateService.handle`.
3. Accepted: accept loop exits only when stopped; transient errors back off 100 ms.
4. Partly accepted: unauthorized → one reply, then close; max 128 connections (`Defaults.maxConnections`). Idle read timeout REJECTED: subscribers are idle by design.
5. Accepted: SO_SNDTIMEO 2 s on accepted fds (`Defaults.serverSendTimeout`); stalled subscriber → push throws `.timeout`, connection ends.
6. Accepted: `start()` probe-connects; live server → `SocketError.alreadyRunning`; unlink only on ECONNREFUSED; `stop()` of a never-started server no longer unlinks.
7. Accepted: build-lock atomic stale takeover (mv + rm, retry mkdir); pid-less lock dir older than 10 s is stale.
8. Accepted as `MessageServer(onDisconnect:)` hook + `RequestContext.connectionId`; fand safety layers (setMode auto on quit / onDisconnect / 10 s watchdog, separate subscribe vs control connections) documented in FanProtocol.swift.
9. Accepted: `Defaults.maxCommandBytes` 4 KiB, `CommandText.capped` (marker `…[truncated]`), applied by `AcquireRequest.init`; Lease.command may be truncated; hookCheck command not truncated (needed for wrap); `maxLineBytes` raised to 4 MiB (worst-case status test).
10. Accepted: `call()` uses one overall deadline across all syscalls; timeout ≤ 0 = immediate timeout.
11. Accepted: `stop()` uses `LineConnection.shutdown()` guarded by the close lock.
12. Accepted: (a) tickets per (session, cwd), `unknown` never shares (`Ticket.cwd` added); (b) `run --ticket` still queued → busy, ticket kept; (c) `CgateExit.spawnFailed` 70, `interrupted` 130; (d) FanMode.auto doc: Ftst optional.
13. Accepted: tests for partial/oversized lines, 0.5 s overall deadline (trickle + silent server), timeout 0, stale socket vs alreadyRunning, connection cap + concurrency, unauthorized close, onDisconnect, stalled subscriber. Accept-loop resilience (EMFILE) not unit-tested: needs process-wide RLIMIT changes that would disturb parallel suites.
Round 2: M1, L1, L2, L3 accepted and fixed
