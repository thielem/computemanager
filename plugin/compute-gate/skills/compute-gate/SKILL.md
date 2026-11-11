---
name: compute-gate
description: Run heavy commands (builds, test suites, docker builds) through the compute gate with `cgate run`. Use before any long or CPU-heavy command, and when a tool call is denied with "Compute gate: heavy command", "compute busy", "Compute gate off", a stop notice or "slot ready".
---

# Compute gate

The user's machine has a limited number of slots for heavy runs. Respect it.

- **Always run heavy work via cgate, in the background:** Bash with `run_in_background: true` and
  the whole command line quoted as ONE argument:
  `cgate run --max 10m -- 'cd x && make'` (`--max` = your estimate; default 15m, cap 60m).
  Several arguments after `--` are run directly as argv (`cgate run -- make -j8`); one argument is
  a shell line. A `cd` inside the quoted line does not persist after the command.
  Keep making tool calls meanwhile so you see notices.
- **Chains:** use `--wait` so each step queues instead of failing busy:
  `cgate run --wait --max 10m -- 'make' && cgate run --wait --max 5m -- 'make test'`.
  `--wait` blocks until the slot is free, then runs (exit 76 if the gate goes off, 79 if the
  ticket expires).
- **Exit code = last command of a pipeline:** don't pipe into `tail`/`head`; redirect
  (`> /tmp/x.log 2>&1`) and read the file afterwards.
- ETAs ("next slot by ~10:53 (latest)") are upper bounds: running jobs' declared max runtimes.
- **Denied with "Compute gate: heavy command. Re-run as: …":** the hook does not run it for
  you; re-run exactly the suggested line (fill in `--max`) with `run_in_background: true`.
- **Busy (exit 75, "compute busy: ticket N …"):** don't retry in a loop. Start
  `cgate wait --ticket N` with `run_in_background: true` right away; you'll be notified when it
  completes. Don't rely on any other message (as a subagent you get no pushes). Do other work
  meanwhile. When it completes with "Slot ready", run
  `cgate run --ticket N --max <est> -- '<cmd>'` within the hold time it states.
- **Gate off (exit 76):** continue without heavy runs, or stop and report.
- **Stop notice** (tool call denied with "compute gate: …"): stop your heavy job now
  (stop the background task), start no new ones, then continue without them or report.
- **Killed** (exit 77 walltime / 78 user): don't rerun blindly; raise `--max` only if justified,
  otherwise report.
- `cgate status` shows slots, running jobs and the queue.
