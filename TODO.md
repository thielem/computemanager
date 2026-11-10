# TODO (user, non-code)

| # | Item | When | Who |
|---|---|---|---|
| 1 | Quit other fan tools (Stats fan control, Macs Fan Control) so nothing fights over SMC | Before M0a | User |
| 2 | Run `sudo ./install.sh` once (installs fand LaunchDaemon) | After package A | User |
| 3 | Approve launch-at-login (System Settings → General → Login Items) | First app launch | User |
| 4 | Install plugin: `claude plugin install …` (user scope) | After package C | User |
| 5 | Decide: add CLAUDE.md snippet globally (`~/.claude/CLAUDE.md`) or rely on plugin skill | Before E2E | User |
| 6 | Answer open decisions O1–O6 (PLAN.md §11) | Any time | User |

## Back out

| Step | Command |
|---|---|
| Remove daemon, plist, socket; fans → Auto | `sudo ./uninstall.sh` |
| Remove plugin | `claude plugin uninstall compute-gate` |
| Remove login item | System Settings → Login Items |
| Remove app | delete `ComputeManager.app` |
