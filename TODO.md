# TODO (user, non-code)

| # | Item | When | Status |
|---|---|---|---|
| 1 | Quit other fan tools (Macs Fan Control, Stats fan control) so nothing fights over SMC | Before M0a | Done (Macs Fan Control quit) |
| 2 | Run M0a probe once: `sudo spikes/smc-probe` (read → Max ≤10 s → Auto), report result | M0 | Open |
| 3 | Install (order below) | After merge | Open |
| 4 | Approve launch-at-login (System Settings → General → Login Items) | First app launch | Open |
| 5 | Confirm plugin name (O7) | Before package C | Done (`compute-gate`) |

## Install (in this order)

1. `sudo scripts/install.sh` (fand LaunchDaemon)
2. `scripts/bundle.sh`, move `build/ComputeManager.app` to `/Applications`, launch it
3. `scripts/install-cgate.sh` (→ `~/.local/bin/cgate`)
4. `claude plugin marketplace add ~/Documents/GitHub/computemanager`
5. `claude plugin install compute-gate@computemanager`
6. Add the line from `docs/claude-md-snippet.md` to `~/.claude/CLAUDE.md`

## Back out

| Step | Command |
|---|---|
| Remove daemon, plist, socket; fans → Auto | `sudo scripts/uninstall.sh` |
| Remove plugin | `claude plugin uninstall compute-gate` |
| Remove login item | System Settings → Login Items |
| Remove app | delete `/Applications/ComputeManager.app` |
| Remove cgate | `rm ~/.local/bin/cgate` |
