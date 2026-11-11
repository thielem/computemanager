# job-stop status

## Done
- Two-step per-job stop (27d319d): first press on a job's ✕ = soft stop. The lease goes to `stopRequested`, reason `userKill`; the job-specific notice is queued for the hook and pushed. No signal. Second press = hard kill (the old killJob behaviour). The button is red while `stopRequested` (gate state, so it also covers gate soft stop and the walltime notice). Tooltips: "Ask to stop" / "Kill". A per-job soft stop survives the gate going back on.
- Configurable ticket hold (30 s–10 min) and kill grace (10 s–5 min) in Settings → Runtime (a314c67).
- Agent texts state the concrete timings from settings: walltime grace, hold, and "not killed automatically unless the user escalates".
- Subagent attribution (40eba0f, exact matching in the review fixes): the hook passes `agent_id`. For every `cgate run … -- <cmd>` in a Bash line (any segment, prefixes, `bash -c`), the hook rebuilds the command text exactly as cgate sends it (one word raw, several shell-quoted, redirections dropped, capped at 4 KB) and stashes one entry per invocation for 15 s, for subagents and the main session (agent nil). An acquire claims the entry with the same (session, command), same cwd preferred, oldest first. Last resort: a subagent entry whose text contains the acquired command, and only when no main-session entry also matches. Tickets are keyed by (session, agent, cwd). Notices are delivered only to the matching agent. Subagent-owned items are never pushed. The job row shows a short agent id.
- Menu panel: MenuBarExtra replaced by NSStatusItem + NSPopover (transient, NSHostingController with `.preferredContentSize`). Left click toggles. The `.fixedSize` hack was removed. Popover close cancels the gate-off choice. ⌘, / ⌘Q, single instance, the DEBUG snapshot and COMPUTEMANAGER_OPEN_SETTINGS still work. New DEBUG `COMPUTEMANAGER_OPEN_MENU=1` opens the popover via `performClick` and logs its window number. Screenshots (scratchpad `popover-jobs.png`, `popover-nojobs.png`): rounded corners, border, no clipping.
- Review fixes: 0 slots (gate on) = closed (`.off` with `CgateMessage.noSlots`, exit 76; no ETAs; `cgate wait` and `run --wait` exit 76). New `cancelTicket` op: `run --wait` cancels its ticket on any exit or signal while waiting. Job-specific notices (walltime, job stop, kill) are dropped when the lease ends (release or reap). e2e greps fixed; `scripts/e2e/cli.sh` 26/26 green.
- `cgate run --wait`; git job labels; ETAs worded as upper bounds; pipe note in usage and SKILL; Slots stepper allows 0 (9ad52ae).

## In progress
—

## Blocked
—

## Questions
—

## Contract-change requests (approved by orchestrator, applied)
- `KillJobRequest.soft: Bool?` (nil = hard).
- `GateSettings.ticketHoldSeconds` / `walltimeGraceSeconds`, decoded with defaults when missing.
- `TicketInfo.holdSeconds?`.
- `HookCheckRequest.agentId?`; `Lease.agentId?` / `Ticket.agentId?`.
- `AcquireRequest.label?` / `Lease.label?`.
- `cancelTicket` op (`CancelTicketRequest`, empty reply). An old app answers `unknownOp`, and the ticket then expires on its own. `CgateMessage.noSlots`.
- New CgateMessage builders/texts: `jobStopNotice`, `busyWaiting`, `latest`, `human`; `walltimeNotice` and `slotReady` take timings. No new StopReason.

## Compatibility
- Old installed cgate + new app: works. Unknown JSON fields are ignored, and a per-job soft stop arrives as the existing `softStop(userKill)` heartbeat directive. The old cgate prints the generic soft-stop line on stderr; the agent gets the job-specific text through the hook and push.
- An old cgate hook sends no `agent_id`, so everything stays main-session, as before.
- Reinstalling cgate is only needed for: subagent attribution (hook `agent_id`), `--wait`, labels, and the new stderr texts in `cgate run`/`wait`/`status`.

## Notes
- A reattach after an app restart loses the agent id (the acquire carries none), so the job falls back to the main session.
- A change to the kill grace also moves kills already in their grace period.
- Attribution is still ambiguous for identical commands from the main session and a subagent in the same session and cwd within 15 s: the oldest entry wins. `cgate wait` needs no attribution because the ticket already carries the agent.
- Gate-level soft/hard-stop notices are per session, not per job, so they stay queued after the job ends.

## Review triage
Round 1: all findings accepted and fixed: e2e busy regex and grep -E parens; exact subagent attribution; 0 slots = closed; `run --wait` ticket cancel; ended-lease notices; flaky `hardStopKillsProcessGroup` (now `eventually`); menu chrome (NSStatusItem + NSPopover). Low #6 ("subagent notices arrive only on the subagent's next tool call") is by design: subagent notices are never pushed, because the session socket would deliver them to the parent.
Round 2 lows fixed: quoted words after `cgate run --` are never dropped as redirections (`grep -c '<div' f`); a signal before spawn exits 128 + signal without spawning, cancelling the ticket and releasing a lease granted in the same window.
