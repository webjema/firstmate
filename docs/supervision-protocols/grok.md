Mode: Grok background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Arm with Grok's tracked background tool, as its own call:

   `run_terminal_command` with `background: true` on:
   `exec bin/fm-watch-arm.sh`

3. Trust only the arm's one-line status.
4. `watcher: started ...`, `watcher: attached ...`, `watcher: standby - ...`, and `watcher: relaunching after <n> quiet exit(s)` all mean a live cycle exists.
   The background task stays live across all of them; the arm exits only when it has something you must act on.
   `watcher: standby - supervision held by arm pid=<pid>` means another arm already owns supervision for this home: that task parks silently and takes over only if that arm ends, so leave it running and do NOT arm again.
5. A background arm task that ENDS without a wake line - a bare completion, a stop, or any line that is not `signal:`, `stale:`, `check:`, `heartbeat`, `watcher: wakes queued (<n>) - drain them`, or `watcher: FAILED - ...` - is not a wake and not the end of supervision.
   Verify with `bin/fm-supervision-live.sh` and do NOT arm again; arm again only when it answers `watcher: DOWN`.
6. `watcher: FAILED ...` means supervision is down; fix and re-arm.
7. After a successful start, attach, or standby status, end the turn.
   The background arm remains the live wait until the cycle ends.
8. Waiting is silent.
9. Never use shell `&` for firstmate supervision.
10. Never bundle the arm onto another command.
    A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) whenever this project's Grok hooks are trusted.

Grok injects a synthetic user message with `synthetic_reason: task_completed` when the background arm completes.
When you see a background-task-completed system reminder for the arm:
1. Run `bin/fm-wake-drain.sh` first.
2. Optionally fetch arm output with `get_command_or_subagent_output(<task_id>)` for the reason line.
3. Handle `signal`, `stale`, `check`, `heartbeat`, or `watcher: wakes queued (<n>) - drain them` using the harness-neutral contract in `AGENTS.md`.
4. Re-arm the next cycle with the same background `bin/fm-watch-arm.sh` call if work remains in flight.
5. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records or a real watcher reason line.
   Because the task's completion IS the wake, the arm ends only on information: a watcher wake reason, queued wake records, or one bounded `FAILED`.
   A watcher that dies with nothing to report is relaunched in place and never reaches you, and a duplicate arm parks as a silent standby rather than exiting; see [../incidents/watch-arm-notification-storm.md](../incidents/watch-arm-notification-storm.md).

Grok Stop hooks are passive.
The primary project hook runs `bin/fm-turnend-guard-grok.sh`, which forces at most one same-session follow-up via `grok --resume` when a turn would end blind.
That is a backstop, not the normal wake path.
After any forced follow-up, arm the watcher with the background protocol above.

Interactive TUI primary sessions are the supported supervision host.
Headless `grok -p` may wait for background process exit but does not reliably surface full auto-wake model output; do not run the primary firstmate as a one-shot headless process.
