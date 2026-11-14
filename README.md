# Compute Manager

A macOS menu bar app that keeps AI coding agents from saturating your Mac. Heavy jobs (builds, test suites) that Claude Code and other agents start go through a gate with a fixed number of slots, and you can pause, stop or kill them from the menu bar. It also controls the fans: Auto, a performance curve, or Max. One click on **Meeting** frees the machine for a call.

## How it works

**Gate.** Agents run heavy work through the `cgate` CLI. The app hosts the gate.

- N slots (default 2). Gate levels: **On**, **No more** (no new runs; running jobs finish), **Soft stop** (agents are asked to stop), **Hard stop** (process groups killed).
- Every run declares a max runtime (`--max`, default 15 min, cap 60 min). When a run exceeds it, its agent gets a notice; after a configurable grace (default 60 s) the run is killed.
- A busy gate answers immediately (exit 75) with a FIFO ticket, queue position and ETA. The agent runs `cgate wait --ticket N` in the background and is woken when its slot is ready. `cgate run --wait` (block until a slot is free) is opt-in.
- Per-job ✕ in the menu: first press = soft stop, second press = kill.
- **Meeting** = No more + fans to Auto.
- App not running: `cgate run` runs ungated and logs to `~/Library/Logs/ComputeManager/cgate-fallback.log`. Quitting the app is the same as not having cgate at all.

**Fans.** `fand`, a root LaunchDaemon, writes the SMC fan keys.

- **Auto** (Apple default), **Performance** (curve on the hottest P-core temperature: minimum RPM at 55 °C, full speed at 85 °C, 3 °C hysteresis; editable in Settings), **Max**.
- In Performance mode, thermal state serious or critical forces full speed.

## Requirements

- Apple Silicon Mac, macOS 14 or later. Tested on an M2 Pro MacBook Pro.
- Claude Code, for the plugin.

## Install

**Homebrew (recommended):**

```sh
brew install --cask thielem/tap/compute-manager
```

Installs the app, the `cgate` CLI and the `fand` daemon (asks for your sudo password).
If you installed from source before, remove that first: `sudo scripts/uninstall.sh`, then delete the app.

**From source:**

```sh
scripts/bundle.sh            # builds build/ComputeManager.app; move it to /Applications or ~/Applications
sudo scripts/install.sh      # fand LaunchDaemon
scripts/install-cgate.sh     # cgate to ~/.local/bin
```

## Claude Code setup

```sh
claude plugin marketplace add thielem/computemanager   # or a local clone: /path/to/computemanager
claude plugin install compute-gate@computemanager
```

The `compute-gate` plugin adds a skill and a PreToolUse hook. The hook denies heavy Bash commands not run through cgate and suggests the line to copy (`cgate run --max <est> -- '<cmd>'`). It also delivers stop and walltime notices. It never rewrites commands. If the app isn't running, the hook stays silent.

Add this line to `~/.claude/CLAUDE.md`:

```
- Run heavy builds/tests via `cgate run --max <est> -- '<cmd>'` with run_in_background.
```

The heavy-command patterns are editable in the app's settings. Matching details are in [plugin/compute-gate/README.md](plugin/compute-gate/README.md).

## cgate quick reference

| Command | What |
|---|---|
| `cgate run [--wait] [--max <dur>] [--session <id>] [--ticket <id>] -- <cmd...>` | Run under the gate. One argument after `--` = shell line, several = argv. `dur`: `90s`, `15m`, `1h30m`, bare number = minutes |
| `cgate wait --ticket <id>` | Block until the ticket's slot is ready (exit 0), then claim it with `cgate run --ticket <id> ...` |
| `cgate status` | Slots, running jobs, queue |
| `cgate hook` | Claude Code hook entry point (reads hook JSON on stdin) |

| Exit | Meaning |
|---|---|
| child's code | `cgate run` passes the command's exit code through (128 + signal if signalled) |
| 64 | Usage error |
| 70 | Command could not be started |
| 75 | Busy; ticket issued |
| 76 | Gate off |
| 77 | Killed: exceeded declared max runtime |
| 78 | Killed by user (hard stop or menu kill) |
| 79 | Ticket expired or unknown |
| 130 | cgate interrupted (signal forwarded to the command) |

## Uninstall

```sh
brew uninstall --cask compute-manager          # removes the daemon; fans go back to Auto
brew uninstall --cask --zap compute-manager    # also removes settings
```

From source: `sudo scripts/uninstall.sh`, then delete the app and `~/.local/bin/cgate`.

## Development

- `scripts/check.sh` builds all targets and runs all tests, printing only errors.
- Builds take a project-wide lock (`scripts/build-lock.sh`): at most one build/test run across all worktrees. Use `scripts/swiftw` instead of `swift` to get the lock.
- `scripts/e2e/`: end-to-end tests against a headless gate host (`cli.sh`) and a real `claude -p` session (`claude.sh`). See [scripts/e2e/README.md](scripts/e2e/README.md).
- Releasing: [docs/RELEASING.md](docs/RELEASING.md).

## Safety notes

`fand` runs as root and writes SMC fan keys. It accepts requests only from the console user. Fans revert to Auto:

- when the app quits or crashes,
- after 10 s without a heartbeat from the app,
- when `fand` starts or stops, and after a reboot,
- on uninstall.

The gate logic runs in the user-level app, never in the root daemon.

## License
MIT, see [LICENSE](LICENSE).
