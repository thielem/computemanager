# Handoff

## State
M1 (fand, menu bar app, GateCore/cgate/plugin) is built, reviewed, e2e-tested and merged into `main` at 5e0ca99; `scripts/check.sh` is green there. Nothing installed or pushed; ~/.claude untouched.

## Open
Branch `main--int-fix2` has unverified WIP for 5 round-2 integration findings:
1. `scripts/e2e/claude.sh` should use a copied plugin with hooks.json pointing to debug `$BIN/cgate`.
2. PLAN.md gate-state table: `level`, `held: [{ticket_id, until}]`, one 2-min hold per free slot.
3. PLAN.md row formatting; fans-revert sentence in its own row/Safety.
4. Quote paths with spaces in `scripts/bundle.sh` PlistBuddy and the FanSection install hint.
5. `scripts/e2e/lib.sh` trap also kills background jobs.

Next: verify each, run `scripts/check.sh` + `bash scripts/e2e/cli.sh`, then merge --no-ff into main (user pre-approved merges into main).

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
