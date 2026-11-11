# job-stop status

## Done
- Two-step per-job stop (27d319d): first press on a job's ✕ = soft stop. The lease goes to `stopRequested`, reason `userKill`; the job-specific notice is queued for the hook and pushed. No signal. Second press = hard kill (the old killJob behaviour). The button is red while `stopRequested` (gate state, so it also covers gate soft stop and the walltime notice). Tooltips: "Ask to stop" / "Kill". A per-job soft stop survives the gate going back on.
- Configurable ticket hold (30 s–10 min) and kill grace (10 s–5 min) in Settings → Runtime (a314c67).
- Agent texts state the concrete timings from settings: walltime grace, hold, and "not killed automatically unless the user escalates".
- Subagent attribution (40eba0f): the hook passes `agent_id`. When the hook sees a subagent's `cgate run`, it stashes the attribution for 15 s. The matching acquire (same session, the hook command line contains the acquired command, same cwd preferred, oldest first) gets the agent. Tickets are keyed by (session, agent, cwd). Notices are delivered only to the matching agent. Subagent-owned items are never pushed. The job row shows a short agent id.
- Menu panel: `.fixedSize(vertical:)` so the MenuBarExtra panel resizes instead of clipping (d86127f).
- `cgate run --wait`; git job labels; ETAs worded as upper bounds; pipe note in usage and SKILL; Slots stepper allows 0 (9ad52ae).

## In progress
—

## Blocked
- The real menu panel could not be screen-captured. `performClick` and synthesized NSEvents do not open a MenuBarExtra. A CGEvent click would move the user's real mouse, so it was not used. Only an offscreen render was checked (scratchpad `menu-border-offscreen.png`). The panel fix is a likely cause, not a confirmed one; the user should check it after the next install.

## Questions
—

## Contract-change requests (approved by orchestrator, applied)
- `KillJobRequest.soft: Bool?` (nil = hard).
- `GateSettings.ticketHoldSeconds` / `walltimeGraceSeconds`, decoded with defaults when missing.
- `TicketInfo.holdSeconds?`.
- `HookCheckRequest.agentId?`; `Lease.agentId?` / `Ticket.agentId?`.
- `AcquireRequest.label?` / `Lease.label?`.
- New CgateMessage builders/texts: `jobStopNotice`, `busyWaiting`, `latest`, `human`; `walltimeNotice` and `slotReady` take timings. No new StopReason.

## Compatibility
- Old installed cgate + new app: works. Unknown JSON fields are ignored, and a per-job soft stop arrives as the existing `softStop(userKill)` heartbeat directive. The old cgate prints the generic soft-stop line on stderr; the agent gets the job-specific text through the hook and push.
- An old cgate hook sends no `agent_id`, so everything stays main-session, as before.
- Reinstalling cgate is only needed for: subagent attribution (hook `agent_id`), `--wait`, labels, and the new stderr texts in `cgate run`/`wait`/`status`.

## Notes
- A reattach after an app restart loses the agent id (the acquire carries none), so the job falls back to the main session.
- A change to the kill grace also moves kills already in their grace period.
- `hardStopKillsProcessGroup` failed once (ESRCH race just after SIGKILL) and passed on rerun. It looks pre-existing and flaky.
- `scripts/e2e/cli.sh` greps were updated to the new texts but not run.

## Review triage
—
