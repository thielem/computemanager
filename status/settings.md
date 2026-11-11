# settings status
## Done
- Settings bug fixed: gear opens a hand-managed `NSWindow` (`Views/SettingsWindow.swift`) that activates the app and orders itself front; `SettingsLink` + `Settings` scene removed. `⌘,` works while the menu is open.
- Root cause (reproduced with a DEBUG build):
  1. `Settings` scene from a `MenuBarExtra` in an `LSUIElement` app: the scene is not opened via the action path (`showSettingsWindow:` produced no window at all), and `SettingsLink` doesn't activate the accessory app (the `simultaneousGesture` → `NSApp.activate` never fires on a Button), so at best the window opened behind other apps; no Dock icon → not findable.
  2. `SettingsView` had only a width: a grouped `Form` has no ideal height, so hosted in a window it collapsed to the 28 pt title bar (measured: 380×28). Now fixed size 400×640.
- Controls: default max / cap / patterns / launch at login go through the unchanged `GateService.setSettings` → `gate.json` path (already unit-tested); they were never reachable because the window didn't show. Slots stay in the menu.
- Feature FAN-10: editable Performance curve.
  - Shared (approved contract change): `SetModeRequest.curve: FanCurve?` (optional, old requests decode; old fands ignore it), `FanCurve.clamped(tick:)` + ranges (low 40…80, high low+5…95, hysteresis 0…10, tick fixed).
  - fand: `FandService` clamps the curve, malformed → `badRequest`, nothing changes; `FanController.setMode(_:curve:…)` swaps curve + curve state, applies at once and on every tick; memory only. `FanController.tick` fixed at start.
  - App: `FanStore` (`fan.json` in Application Support) persists the curve; `FanViewModel.setCurve` clamps/persists/sends; every `setMode` (incl. reconnect and shutdown) carries the curve. Settings "Performance" group: Start / Full speed / Hysteresis steppers, Reset (55/85/3). If fand reports a different curve (old fand), the header shows a quiet "Needs fand update".
  - Tests: clamping + optional-field codec (SharedTests), clamp/reject over the socket + curve applied now and on next tick (fandTests), reconnect re-sends mode + curve (FanLinkTests), VM clamp/persist/send + old-fand hint, FanStore round trip.
- Screenshot: `/private/tmp/claude-501/-Users-mthiele-Documents-GitHub-computemanager/73776acb-153c-4021-9b91-b70e2ed5c078/scratchpad/settings-window.png` (DEBUG demo build, opened via `COMPUTEMANAGER_OPEN_SETTINGS=1`, same code path as the gear).
## In progress
## Blocked
- Could not click the real menu bar item (no Accessibility permission for scripted clicks); verified via the DEBUG hook `COMPUTEMANAGER_OPEN_SETTINGS=1`, which calls the same `SettingsWindow.show`. Window came up on screen, near the top of the z-order, 400×668. A real click should also activate the app (user-initiated).
## Questions
## Contract-change requests
- Applied (orchestrator-approved): `SetModeRequest.curve`, `FanCurve.clamped(tick:)` + range constants.
## Review triage
## User must do
- Rebuild/reinstall the app (`scripts/bundle.sh` + replace the installed app) for the Settings fix.
- `sudo scripts/install.sh` for the new fand; until then curve edits are stored but have no effect (fand ignores the field).
