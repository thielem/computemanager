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
  re-sends current `setMode` on every control reconnect and when subscribe reports a different mode
  (watchdog revert; ≤ 1 per 5 s), `setMode auto` on quit. App Nap blocked (beginActivity) while mode ≠ Auto.
  fand absent → picker hidden, one row: warning + selectable `sudo scripts/install.sh` + copy button;
  not responding → disabled picker + one-line note.
- Menu bar glyph: bolt.fill (on) / bolt.badge.clock.fill (off, jobs running) / bolt.slash.fill (off), plus
  fan.fill (Performance) or wind (Max); nothing extra for Auto.
- Settings window: launch at login (SMAppService.mainApp; not toggled here), default max, cap, auto-wrap patterns.
- scripts/bundle.sh → build/ComputeManager.app (release, icon, ad-hoc signed, verified).
- Tests: Tests/ComputeManagerTests (gate-off flow, escalation, meeting, persistence, fand reconnect/re-send
  against a fake FanServer, separate connections, quit → auto).
- Debug builds only: `COMPUTEMANAGER_DEMO=1` (fake gate + fand present) / `=nofan` (fand absent), never
  persisted; `COMPUTEMANAGER_SNAPSHOT=<png>` renders the menu content to PNG (status item is hidden by a menu bar
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
Round 1 (fixed in this branch):
- Accepted 1: cap stepper bounded by `Defaults.maxRuntimeCap` (60 min), default ≤ cap (`SettingsView.setting`, tested).
- Accepted 2: App Nap activity while fan mode ≠ Auto; subscribe mode ≠ desired → re-send setMode, rate-limited 5 s (tested).
- Accepted 3: menu disappear cancels a pending off-choice; switch shows On again (`switchOn`, tested).
- Accepted 4: DEMO/SNAPSHOT only under `#if DEBUG`; demo never persists to gate.json.
- Accepted 5: patterns commit on focus loss / disappear / 1.5 s debounce; reload on external change while not editing.
- Accepted 6: snapshots stamped with a monotonic sequence at arrival; stale GateStatus/FanStatus dropped (tested).
- Accepted 8: undecodable gate.json logged and kept as gate.json.bak (tested).
- Accepted 9: no section headings (gate row = bolt glyph + state + switch); fand-absent single row; fan readout = hottest CPU + both RPMs.
- Rejected 7 (quit may block ≤ ~4 s if fand hangs): acceptable; fand reverts to Auto on disconnect anyway.
- Rejected 10 (per-job kill without confirmation): user prefers speed.
