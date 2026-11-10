---
name: compute-gate
description: Run heavy commands (builds, test suites, docker builds) through the compute gate with `cgate run`. Use before any long or CPU-heavy command, and when a tool call is denied with "compute busy", "Compute gate off", a stop notice or "slot ready".
---

# Compute gate

The user's machine has a limited number of slots for heavy runs. Respect it.

- **Run heavy work in the background:** Bash with `run_in_background: true` and
  `cgate run --max <estimate> -- <cmd>` (e.g. `--max 10m`; default 15m, cap 60m). Keep making
  tool calls meanwhile so you see notices. Matching commands (pytest, swift build/test, make, …)
  are wrapped automatically.
- **Busy (exit 75, "compute busy: ticket N …"):** don't retry in a loop. Start
  `cgate wait --ticket N` in the background and do other work. When it completes with
  "slot ready", run `cgate run --ticket N --max <est> -- <cmd>` within the hold time.
- **Gate off (exit 76):** continue without heavy runs, or stop and report.
- **Stop notice** (tool call denied with "compute gate: …"): stop your heavy job now
  (stop the background task), start no new ones, then continue without them or report.
- **Killed** (exit 77 walltime / 78 user): don't rerun blindly; raise `--max` only if justified,
  otherwise report.
- `cgate status` shows slots, running jobs and the queue.
