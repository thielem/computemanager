# p0-foundations status

## Done
- Env check: Swift 6.4.2, Xcode 27.2 (full Xcode, macOS 27.2 SDK), uv 0.12.21, pnpm 11.10.0 (via corepack).
- PLAN.md: O6/O7 resolved (fan control must, no read-only fallback; plugin `compute-gate`); TODO #7 done.
- SwiftPM skeleton: Shared, GateCore (libs); ComputeManager (MenuBarExtra), fand, cgate (executables); tests for Shared/GateCore/cgate.
- Shared contracts: envelope + codecs, fand protocol, gate protocol, gate model, cgate exit codes/messages, durations, defaults, paths, Unix socket NDJSON client/server with tests.
- scripts/check.sh + scripts/swiftw under project-wide build lock (/tmp/computemanager-build.lock), CONVENTIONS.md.
- PLAN.md: M0 findings recorded (no Ftst key → optional; F{n}Md ui8 + F{n}Tg flt; Mn 2317 / Mx 6800; messaging socket format; process tree).
- Shared: ClaudeMessaging env names. check.sh green: 19 tests.

## In progress
- none

## Blocked
- none

## Questions
- none

## Contract-change requests
- n/a (orchestrator-owned package)

## Review triage
- n/a
