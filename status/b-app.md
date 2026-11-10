# b-app status

## Done
- App shell: MenuBarExtra (.window), LSUIElement (Resources/Info.plist), AppDelegate launch/terminate.
  Single instance: gate server `start()` → `alreadyRunning` → alert + quit (duplicate never touches fans).
- Persistence: `~/Library/Application Support/ComputeManager/gate.json` {settings, level}; saved on level/settings
  change. softStop/hardStop are restored as noMore (reattached jobs must not be killed after a restart).
- Gate VM (`Model/GateViewModel.swift`) over own `GateBackend` protocol (GateService conforms via extension;
  `FakeGate` in tests, `DemoGate` for `COMPUTEMANAGER_DEMO=1`). Off with running jobs → No more / Soft / Hard
  inline choice; escalation No more → Soft → Hard while off and jobs run; slots stepper keeps level; kill per job;
  queued count. Meeting = gate `meeting` + fans Auto.
- Fan: `FanLink` with separate subscribe thread + control queue, heartbeat 2 s, exponential backoff (0.5→8 s),
  re-sends current `setMode` on every control reconnect, `setMode auto` on quit. Unreachable → one-line
  "Fan helper not installed: sudo scripts/install.sh" (socket missing) or "not responding".
- Menu bar glyph: bolt.fill (on) / bolt.badge.clock.fill (off, jobs running) / bolt.slash.fill (off), plus
  fan.fill (Performance) or wind (Max); nothing extra for Auto.
- Settings window: launch at login (SMAppService.mainApp; not toggled here), default max, cap, auto-wrap patterns.
- scripts/bundle.sh → build/ComputeManager.app (release, icon, ad-hoc signed, verified).
- Tests: Tests/ComputeManagerTests (gate-off flow, escalation, meeting, persistence, fand reconnect/re-send
  against a fake FanServer, separate connections, quit → auto).
- Debug: `COMPUTEMANAGER_SNAPSHOT=<png>` renders the menu content to PNG (status item is hidden by a menu bar
  manager on this machine and System Events has no accessibility permission).

## In progress
- none

## Blocked
- none

## Questions
- none

## Contract-change requests
- none

## Review triage
- n/a
