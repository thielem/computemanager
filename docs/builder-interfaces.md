# Builder interfaces

Shared code is frozen and owned by the orchestrator. Change requests go in `status/<pkg>.md`. `Package.swift`: additive edits only.

## Ownership

| Pkg | Branch | Owns |
|---|---|---|
| A `fand` | `main--a-fand` | `Sources/fand/**`, `Tests/fandTests/**` (new target; additive `Package.swift` edit), `scripts/install.sh`, `scripts/uninstall.sh`, `packaging/launchd/*.plist` |
| B app UI | `main--b-app` | `Sources/ComputeManager/**`, `scripts/bundle.sh`, `Resources/` (icons, Info.plist), launch-at-login |
| C gate | `main--c-gate` | `Sources/GateCore/**`, `Sources/cgate/**` (run, wait, hook, status), `Tests/GateCoreTests`, `Tests/cgateTests`, `plugin/compute-gate/**` |
| Shared | orchestrator | everything else (frozen) |

## Scope

| Pkg | Deliverables |
|---|---|
| A | SMC client (reuse `spikes/fanprobe` logic), fan curve, watchdog, wake re-apply, optional Ftst, peer-UID auth |
| B | Hosts `GateService` via `GateService(settings:level:)` + `onChange`; mutates only via `handle(...)`. Talks to fand via `FanClient` over separate subscribe/control connections; heartbeat 2 s; re-send `setMode` after reconnect; `setMode auto` on quit. Native UI per design-taste-frontend principles |
| C | `GateService` implementation: state machine, leases, tickets, ETA, reaper, walltime, stop notices, messaging-socket push. Plugin: `hooks/hooks.json`, `skills/compute-gate/SKILL.md`, bin or install note |

## Cross-builder dependencies

| From | On | Only through | Until then |
|---|---|---|---|
| B | C | frozen `GateService` init / `onChange` / `handle` | fake in previews/tests |
| B | A | `FanProtocol` over the socket | fake `FanServer` in tests |
