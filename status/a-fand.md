# a-fand status

## Done
- SMC module (`Sources/fand/AppleSMC.swift`, `SMCKeyIO.swift`): IOKit AppleSMC selector 2, 80-byte SMCParam, key-info-derived types (flt, ui8, ui16, ui32, si8, si16, fpe2, sp78, ioft, flag), key-info cache, `#KEY` enumeration. `SMCKeyIO` protocol, fake in tests.
- `FanHardware`: discovery (FNum, F{n}Mn/Mx, optional Ftst, Tp*/Te*/Tg* keys), hottest plausible temp (5…130 °C), write allowlist (`F{n}Md`, `F{n}Tg`, `Ftst` only), target clamp [Mn, Mx], writes only when needed (Md≠manual, |Tg−target|>1).
- `FanController` state machine: auto / performance / max; curve 55→85 °C with 3 °C dead-band hysteresis; thermalState ≥ serious → Mx; no plausible P-core sensor → Mx. Safety: Auto at start, SIGTERM/SIGINT/SIGHUP, control-connection disconnect, watchdog (10 s, checked per 2 s tick → revert within ≤ 12 s), wake re-apply (IORegisterForSystemPower) + per-tick re-assert if SMC dropped manual.
- `FandService`: FanServer at `Paths.fandSocket` (0666 + peer-UID check: root or console user via SCDynamicStoreCopyConsoleUser), ops status / setMode / heartbeat / subscribe (immediate push, then every tick 2 s + on setMode/revert/wake).
- CLI: `fand` (daemon), `fand --print-status` (read-only JSON, unprivileged), `fand --revert-auto` (root, one-shot), `fand --version`.
- `scripts/install.sh`, `scripts/uninstall.sh`, `packaging/launchd/com.computemanager.fand.plist` (not run).
- Tests: `Tests/fandTests` (28 tests: codec, allowlist, discovery, clamp, curve/hysteresis, modes, watchdog, disconnect, wake, shutdown, socket E2E with fake SMC, peer auth). check.sh green.
- Verified on hardware (read-only): `--print-status` → 2 fans 2317–6800, Ftst absent, Tp=54 Te=3 Tg=10, SMCParam 80 bytes.

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
