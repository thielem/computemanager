# Compute Manager — Plan

## 1. Context

| Item | Value |
|---|---|
| Product | macOS menu bar app: fan modes + compute gate for AI agents |
| Machine | MacBook Pro 14" (Mac14,9), M2 Pro, 2 fans, macOS 27.0.1 |
| Users | Single user, local only |
| Agents in scope | Claude Code only (for now) |
| Core use case | User needs the machine (e.g. video call) → flip gate off, fans to Auto |
| Distribution | Local build, ad-hoc signed (`codesign -s -`), no notarization |
| Status | Planning; repo empty |

### Terms

| Term | Meaning |
|---|---|
| Gate | Global on/off switch + N concurrent slots for heavy agent runs |
| Slot | One permit for a concurrently running heavy run (default N=2) |
| Heavy run | Command executed via `cgate run` (explicit or auto-wrapped by hook) |
| Lease | Registry record of a heavy run holding a slot |
| Walltime / max | Declared max runtime of a run; exceeded → killed |
| Ticket | Reservation for a rejected session (O1) |
| Stop notice | Message delivered to an agent session on Soft/Hard stop |
| fand | Root LaunchDaemon that talks to the SMC |
| cgate | CLI used by hooks and agents to talk to the gate |
| SMC | System Management Controller (fan/temperature keys) |

## 2. Requirements

Priority: M = must, S = should, C = could.

### FAN

| ID | Requirement | Pri |
|---|---|---|
| FAN-1 | Modes: Auto (Apple default), Performance (custom curve), Max (all fans max RPM) | M |
| FAN-2 | Performance curve: hottest P-core temp; ≤55 °C → min RPM, linear to max RPM at 85 °C; 3 °C hysteresis; 2 s tick | M |
| FAN-3 | Performance: `thermalState ≥ .serious` → force max RPM | M |
| FAN-4 | SAFETY: fans revert to Auto (`F*Md=0`, `Ftst=0`) on app quit, crash, or disconnect | M |
| FAN-5 | SAFETY: app heartbeat every 2 s; fand reverts to Auto after 10 s without heartbeat | M |
| FAN-6 | SAFETY: fand reverts to Auto on start and on SIGTERM; after reboot = Auto | M |
| FAN-7 | Re-apply manual mode after sleep/wake (SMC resets) | M |
| FAN-8 | Report per-fan actual/min/max RPM and key temps to app | M |
| FAN-9 | fand accepts requests only from console user's UID (peer creds) | M |
| FAN-10 | Curve parameters editable in settings | C |

### GATE

| ID | Requirement | Pri |
|---|---|---|
| GATE-1 | Global on/off + N slots (default 2) | M |
| GATE-2 | No blocking queue: no free slot → immediate busy response with queue position + ETA of next free slot | M |
| GATE-3 | ETA = min over running leases of `started_at + max_runtime` | M |
| GATE-4 | Every run has max runtime; default 15 min (configurable), hard cap 60 min | M |
| GATE-5 | Walltime exceeded → SIGINT, SIGTERM, SIGKILL after 5 s grace, whole process group; print `killed: exceeded declared max runtime` | M |
| GATE-6 | Lease held for process lifetime, released on exit; app reaps leases with dead pid | M |
| GATE-7 | Gate off with running jobs → user picks No new / Soft stop / Hard stop | M |
| GATE-8 | No new: running finish; new denied with "Compute gate off — continue without heavy runs or stop and report" | M |
| GATE-9 | Soft stop: stop notice + deny new; running job SIGINT (O2) | M |
| GATE-10 | Hard stop: stop notice + SIGTERM process group, SIGKILL after 5 s | M |
| GATE-11 | App not running → cgate allows everything, appends to fallback log | M |
| GATE-12 | Reservation tickets: rejected session gets ticket; freed slot held 2 min for oldest ticket (O1) | S |
| GATE-13 | Gate logic hosted in user-level app, never in root daemon | M |

### AGENT

| ID | Requirement | Pri |
|---|---|---|
| AGENT-1 | `cgate run [--max <dur>] [--session <id>] -- <cmd>` | M |
| AGENT-2 | PreToolUse Bash hook rewrites matching commands to `cgate run --session <id> -- <cmd>` via `updatedInput` + `permissionDecision: allow`; preserves `description`, `timeout`, `run_in_background` | M |
| AGENT-3 | Already-wrapped commands pass through unchanged | M |
| AGENT-4 | Auto pattern list (editable): pytest, xcodebuild, swift build/test, check.sh, pnpm/npm build/test, vitest, playwright, cargo build/test, docker build, make | M |
| AGENT-5 | PreToolUse `"*"` hook: pending stop notice for session → deny once with notice text | M |
| AGENT-6 | Session id: from hook stdin `session_id`; explicit runs fall back to parent-pid lookup, else `unknown` | M |
| AGENT-7 | Hook latency ~ms; app unreachable → fail-open | M |
| AGENT-8 | Claude Code plugin (user scope): hooks.json + skill `compute-gate` + cgate on PATH | M |
| AGENT-9 | `cgate status` (gate state, slots, running jobs, ETA) | S |
| AGENT-10 | Secondary notice channel via Claude Code messaging socket (if M0b spike succeeds) | C |
| AGENT-11 | Optional CLAUDE.md snippet explaining etiquette | S |

### UI

| ID | Requirement | Pri |
|---|---|---|
| UI-1 | Menu bar icon reflects gate on/off + fan mode | M |
| UI-2 | Fan mode picker with temps + RPM | M |
| UI-3 | Gate toggle + slots stepper | M |
| UI-4 | Running jobs: project, command, session short id, elapsed / max, per-job kill | M |
| UI-5 | Off-with-running-jobs prompt: No new / Soft stop / Hard stop | M |
| UI-6 | Settings: pattern list, default/max runtime | M |
| UI-7 | Launch at login (`SMAppService.mainApp`) | M |
| UI-8 | Minimal text, native, compact | M |
| UI-9 | "Meeting" preset: gate off (No new) + fans Auto (O3) | C |
| UI-10 | Banner when fand not installed/unreachable | S |

### INST

| ID | Requirement | Pri |
|---|---|---|
| INST-1 | `sudo ./install.sh`: install fand binary + LaunchDaemon plist in `/Library/LaunchDaemons`, load it | M |
| INST-2 | `uninstall.sh`: unload, remove daemon/plist/socket, fans → Auto | M |
| INST-3 | Bundle script builds `.app` from SwiftPM, ad-hoc signs | M |
| INST-4 | Plugin install via `claude plugin install`; cgate symlinked into PATH | M |
| INST-5 | `scripts/check.sh`: swift build + swift test (+ swiftformat/lint if cheap) | M |

## 3. Architecture

```
                    ┌──────────────────────────── user session ───────────────────────────┐
 Claude Code ──hook──▶ cgate hook ──┐                                                    │
 Claude Code ──Bash──▶ cgate run ───┤  gate.sock (~/Library/Application Support/         │
                                    │  ComputeManager/gate.sock, 0600)                   │
                                    ▼                                                    │
                       ┌────────────────────────────┐                                    │
                       │ ComputeManager.app (user)  │  MenuBarExtra UI                   │
                       │  ├─ GateCore (lib)         │  leases, slots, ETA, notices       │
                       │  └─ FanClient              │  heartbeat 2 s                     │
                       └─────────────┬──────────────┘                                    │
                                     │ /var/run/computemanager/fand.sock                  │
 ────────────────────────────────────┼─── root ──────────────────────────────────────────┘
                                     ▼
                       ┌────────────────────────────┐
                       │ fand (LaunchDaemon, root)  │  curve loop, watchdog → Auto
                       └─────────────┬──────────────┘
                                     ▼ IOKit AppleSMC (selector 2)
                                    SMC
```

| Component | Job | Can read | Cannot read |
|---|---|---|---|
| fand (root) | SMC read/write, curve loop, heartbeat watchdog, revert to Auto | SMC keys, thermal state, peer UID of socket client | Gate state, jobs, commands, user files |
| ComputeManager.app (user) | UI, hosts GateCore, fan client, heartbeat, settings | Gate/lease state, fand status, own settings | SMC directly, other users' data |
| GateCore (lib in app) | Slots, leases, ETA, tickets, stop notices, reaping, gate socket server | Lease records, pids (liveness) | SMC |
| cgate (user CLI) | `run`, `hook`, `status`; walltime enforcement; process-group kill | Hook stdin JSON, env, gate socket | fand socket |
| Plugin | hooks.json, skill, PATH install | — | — |
| Shared (lib) | IPC types, codecs, exit codes, durations | — | — |

## 4. IPC contracts (overview)

Transport: Unix domain sockets, newline-delimited JSON, one request → one response (plus `subscribe` streams). Every message has `v` (protocol version) and `op`.

### fand.sock (`/var/run/computemanager/fand.sock`, owner root, mode 0660 group-restricted or 0666 + UID check)

| op | Request | Response |
|---|---|---|
| `status` | — | fans[], temps, mode, thermalState |
| `setMode` | `mode: auto\|performance\|max` | ok / error |
| `heartbeat` | — | ok (resets 10 s watchdog) |
| `subscribe` | — | stream of `status` every 2 s |

Auth: `getpeereid` / `LOCAL_PEERCRED` UID == console user UID (`SCDynamicStoreCopyConsoleUser`), else reject.

### gate.sock (user, mode 0600)

| op | Caller | Purpose |
|---|---|---|
| `acquire` | cgate run | Request slot; returns `granted` + job_id, or `busy` (position, eta), or `off` (message) |
| `release` | cgate run | Free slot on exit (`exitCode`, `reason`) |
| `heartbeat` | cgate run | Keep lease alive; response may carry `signal: int\|term` (soft/hard stop, UI kill) |
| `hookCheck` | cgate hook | Pending notice for session? → deny text or none |
| `status` | cgate status, UI | Gate state + leases |
| `setGate` | UI | on/off + stop choice, slots |

### cgate exit codes + output

| Code | Meaning | Output (stderr, one line) |
|---|---|---|
| child's | Run completed | — |
| 75 | Busy (no slot) | `compute busy: position <n>, next slot ~<eta>; do other work and retry` |
| 76 | Gate off | `Compute gate off — continue without heavy runs or stop and report` |
| 77 | Walltime kill | `killed: exceeded declared max runtime (<max>)` |
| 78 | Stopped by user (soft/hard/kill) | `stopped by user: <mode>` |
| 64 | Usage error | usage |

Hook mode: busy/off → `permissionDecision: deny` with same text; match → `allow` + `updatedInput`; app unreachable → no output, exit 0 (fail-open).

## 5. Data model

### Lease (job) record

| Field | Type | Notes |
|---|---|---|
| job_id | UUID | |
| session_id | String | `unknown` if absent |
| cwd | String | project = last path component |
| command | String | |
| pid / pgid | Int32 | pgid = cgate's child group |
| started_at | Date | |
| max_runtime | Duration | ≤ 60 min |
| auto_wrapped | Bool | hook vs explicit |
| messaging_socket | String? | from env if present |
| state | running / stopping / done | |

### Gate state

| Field | Type |
|---|---|
| enabled | Bool |
| slots | Int (default 2) |
| off_mode | none / noNew / soft / hard |
| leases | [Lease] |
| tickets | [{session_id, issued_at}] (O1) |
| held_slot | {session_id, until}? (O1) |
| pending_notices | [session_id: text] |
| settings | patterns[], default_max (15 m), hard_cap (60 m) |

Persisted: settings + enabled/slots (UserDefaults). Leases in memory; cgate re-registers on app restart via heartbeat failure → `acquire` retry (no kill).

### Fan state (fand)

| Field | Type |
|---|---|
| mode | auto / performance / max |
| fans | [{id, actual, min, max, target, manual}] |
| temps | {pcore_max, ecore_max, gpu_max} °C |
| thermal_state | nominal / fair / serious / critical |
| last_heartbeat | Date |
| curve | {t_low 55, t_high 85, hyst 3, tick 2 s} |

## 6. Key flows

| Flow | Steps |
|---|---|
| Auto-wrap | Hook reads stdin → pattern match → not already wrapped → `updatedInput.command = cgate run --session <id> -- <cmd>` (other fields preserved) → allow |
| Run granted | cgate `acquire` → granted → spawn child in new pgid → heartbeat 2 s → exit → `release` → exit with child code |
| Run busy | `acquire` → busy → print position + ETA → exit 75 (ticket issued, O1) |
| Walltime | Timer at max → SIGINT pg → +5 s SIGTERM → +5 s SIGKILL → print kill line → exit 77 |
| Gate off: No new | `enabled=false`; running continue; new `acquire` → off (76) |
| Gate off: Soft | + notice queued per running session; leases signalled SIGINT (O2) via heartbeat response |
| Gate off: Hard | + notice; SIGTERM pg, SIGKILL after 5 s |
| Notice delivery | Next tool call → `"*"` hook `hookCheck` → deny once with notice text → notice cleared |
| App down | cgate connect fails → allow, append to `~/Library/Logs/ComputeManager/cgate-fallback.log` |
| Fan mode set | UI → `setMode` → fand: `Ftst=1`, `F*Md=1`, `F*Tg` per tick |
| Fan safety | No heartbeat 10 s / SIGTERM / start / app quit → `F*Md=0`, `Ftst=0` |
| Wake | fand observes wake → re-apply current mode |

## 7. Tech stack

| Choice | Reason |
|---|---|
| Swift 6, SwiftPM only | One language, no Xcode project churn, CLI-buildable |
| SwiftUI `MenuBarExtra` | Native, minimal code |
| IOKit AppleSMC (selector 2) | Only path to fan control; refs: agoodkind/macos-smc-fan, exelban/stats SMC.swift, 2dubu/macfanctl |
| Temps: SMC `Tp*`/`Te*`/`Tg*` (Stats M2 list) or IOHIDEventSystem PMU tdie | Proven on Apple Silicon |
| `ProcessInfo.thermalState` | Extra throttle signal |
| LaunchDaemon (root) | SMC writes need root; minimal surface |
| Unix sockets + NDJSON | Simple, peer creds, no deps, debuggable with `nc -U` |
| `SMAppService.mainApp` | Launch at login |
| Bundle script + `codesign -s -` | No notarization needed for local use |
| swift-testing / XCTest | Built-in |
| Python (if ever) | uv only |

## 8. Repo layout

```
Package.swift
Sources/
  Shared/            IPC types, codecs, exit codes, durations
  GateCore/          state machine, leases, ETA, tickets, socket server
  ComputeManager/    SwiftUI MenuBarExtra app
  fand/              SMC, curve, watchdog, socket server
  cgate/             run / hook / status
Tests/
  SharedTests/  GateCoreTests/  fandTests/  cgateTests/
plugin/
  .claude-plugin/plugin.json
  hooks/hooks.json
  skills/compute-gate/SKILL.md
  bin/cgate -> (symlink/installed)
packaging/
  com.computemanager.fand.plist
  Info.plist
scripts/
  check.sh  bundle.sh
install.sh  uninstall.sh
spikes/              M0 throwaway (smc-probe, msg-probe)
PLAN.md  TODO.md  CONVENTIONS.md
```

## 9. Security

| Measure | Detail |
|---|---|
| Least privilege | Only fand is root; gate logic is user-level |
| Narrow root API | fand ops: status/setMode/heartbeat/subscribe; no raw SMC key writes over IPC |
| Peer auth | `getpeereid`/`LOCAL_PEERCRED` UID == console user; reject otherwise |
| Socket perms | fand.sock in `/var/run/computemanager/` (root-owned dir 0755, socket restrictive); gate.sock 0600 in user dir |
| Fail-safe fans | Watchdog 10 s, revert on start/SIGTERM/quit; reboot = Auto |
| SMC key allowlist | fand writes only `Ftst`, `F{n}Md`, `F{n}Tg` |
| Target clamp | `F{n}Tg` clamped to `[F{n}Mn, F{n}Mx]` |
| Input validation | Max line length, schema-checked JSON, version field |
| Fail-open gate | Gate never blocks the user's own work when app is down |
| Process kills | Only pgids of cgate-spawned children; never arbitrary pids |
| Install | Root files owned root:wheel, 0755/0644; uninstall removes all |

## 10. Milestones

### M0 — Spikes
- [ ] (a) Root CLI `spikes/smc-probe`: read FNum/F0Ac/F0Mn/F0Mx; write `Ftst=1`, `F0Md=1`, `F0Tg`; verify RPM changes; restore Auto (`F0Md=0`, `Ftst=0`) on macOS 27.0.1
- [ ] (b) Probe `CLAUDE_CODE_MESSAGING_SOCKET`/`_TOKEN` from a Bash child: wire format, delivery timing
- [ ] Report; (a) fails → back to user (O6); gate work proceeds anyway

### M1 — Foundations
- [ ] SwiftPM skeleton (targets above)
- [ ] Shared: fand protocol, gate protocol, cgate exit codes + output format
- [ ] `scripts/check.sh`, `CONVENTIONS.md`

### M1 — Parallel packages

| Pkg | Scope |
|---|---|
| A | fand (SMC, temps, curve, watchdog, wake, peer auth) + install.sh / uninstall.sh + LaunchDaemon plist |
| B | Menu bar app UI (fan picker, gate toggle, slots, jobs list, stop prompt, settings, login item) + bundle.sh |
| C | GateCore (state machine, leases, ETA, tickets, notices, reaper, socket server lib used by app) + cgate CLI + hooks + plugin + skill |

### M2 — Integration & verification
- [ ] Wire app ↔ GateCore ↔ fand
- [ ] Review loop (max 2 rounds)
- [ ] E2E with real Claude Code session: busy feedback, walltime kill, soft stop, hard stop, notice delivery, fan revert on app quit/kill -9

## 11. Open decisions

| # | Decision | Default |
|---|---|---|
| O1 | Reservation tickets (slot held 2 min for oldest rejected session) | Implement (S) |
| O2 | Soft stop also SIGINTs running job | Yes (test runners exit cleanly) |
| O3 | "Meeting" preset (gate off/No new + fans Auto) | Add if cheap (C) |
| O4 | Scope: stop after M0 for review, or continue | Continue unless M0a fails |
| O5 | Check-in style | Status updates, no waiting |
| O6 | Fan writes don't work on macOS 27 | Ship gate only; fan section read-only |
