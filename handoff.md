# Handoff

## State
M1 (fand, menu bar app, GateCore/cgate/plugin) is built, reviewed, e2e-tested and merged into `main` at 5e0ca99; `scripts/check.sh` is green there. Nothing installed or pushed; ~/.claude untouched.

## Done (int-fix2, merged)
Round-2 integration fixes verified and merged: e2e claude.sh uses a plugin copy with debug cgate, PLAN.md gate-state/rows fixed, quoted paths in bundle.sh/FanSection, e2e trap kills jobs.
Identifiers are now `com.moritzthiele.cgate` (app bundle) and `com.moritzthiele.cgate.fand` (LaunchDaemon label/plist).

## User's next steps (TODO.md order)
1. `sudo scripts/install.sh`
2. `scripts/bundle.sh`, move app to /Applications, open it
3. Test fans (Max, Performance, quit -> Auto, Meeting)

ONLY after the user confirms the app works:
- run `scripts/install-cgate.sh`
- `claude plugin marketplace add ~/Documents/GitHub/computemanager`
- `claude plugin install compute-gate@computemanager`
- add the line from `docs/claude-md-snippet.md` to ~/.claude/CLAUDE.md

## Untested
- Notice push into an idle interactive session
- Agent wake when `cgate wait` completes
- Real app + fans

## Decisions (don't re-ask)
- Hook never rewrites; denies heavy unwrapped commands with copyable `cgate run --max <est> -- '<cmd>'`; silent if app down.
- Levels: noMore = slots 0 / softStop = notice only / hardStop = kill.
- Walltime: notice, then kill after 60 s.
- FIFO tickets with 2-min holds + ping.
- Fans always Auto on app quit/crash.
- Meeting = noMore + fans Auto.
- Slots default 2.
- Process: orchestrator does no hands-on work, max 4 subagents, 1 build/test run at a time in this project, sonnet for simple tasks never for reviews, max 2 review rounds then ask, work only on main and main--<pkg> sub-branches.
