# TODO (user, non-code)

| # | Item | When | Status |
|---|---|---|---|
| 1 | Quit other fan tools (Macs Fan Control, Stats fan control) so nothing fights over SMC | Before M0a | Done (Macs Fan Control quit) |
| 2 | Run M0a probe once: `sudo spikes/smc-probe` (read → Max ≤10 s → Auto), report result | M0 | Open |
| 3 | Run `sudo ./install.sh` once (installs fand LaunchDaemon) | After package A | Open |
| 4 | Approve launch-at-login (System Settings → General → Login Items) | First app launch | Open |
| 5 | Install plugin: `claude plugin install …` (user scope) | After package C | Open |
| 6 | Decide: add CLAUDE.md snippet globally (`~/.claude/CLAUDE.md`) or rely on plugin skill | Before E2E | Open |
| 7 | Confirm plugin name (O7) | Before package C | Done (`compute-gate`) |

## Back out

| Step | Command |
|---|---|
| Remove daemon, plist, socket; fans → Auto | `sudo ./uninstall.sh` |
| Remove plugin | `claude plugin uninstall compute-gate` |
| Remove login item | System Settings → Login Items |
| Remove app | delete `ComputeManager.app` |
