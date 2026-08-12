Mode: Claude background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Run `bin/fm-watch-arm.sh` as its own Claude Code background task.
3. Never bundle the arm command with other commands.
4. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.claude/settings.json`.
5. Treat `watcher: started ...`, `watcher: attached ...`, `watcher: standby - ...`, and `watcher: relaunching after <n> quiet exit(s)` as proof that one live cycle exists.
   The background task stays live across all of them; the arm exits only when it has something you must act on.
   `watcher: standby - supervision held by arm pid=<pid>` means another arm already owns supervision for this home: that task parks silently and takes over only if that arm ends, so leave it running and start no other.
6. A background arm task that ENDS without a wake line is NOT a wake and NOT the end of supervision.
   A bare "completed", a "was stopped", exit code 0 with no output, or any line that is not `signal:`, `stale:`, `check:`, `heartbeat`, `watcher: wakes queued (<n>) - drain them`, or `watcher: FAILED - ...`: verify with `bin/fm-supervision-live.sh` and do NOT arm again.
   Arm again only when it answers `watcher: DOWN`.
   When it answers `watcher: live ...`, another arm is supervising and a second one is the notification loop, not the repair.
7. Treat `watcher: FAILED - ...` as an alarm and repair it before ending the turn.
   It is the only failure the arm reports, and it is bounded: `no live watcher with a fresh beacon` means none could be confirmed, and `watcher will not stay up` means one kept dying with nothing to report until the churn budget ran out (`state/.watch-arm.log` has the per-relaunch detail).
8. When the background task completes with `signal:`, `stale:`, `check:`, `heartbeat`, or `watcher: wakes queued (<n>) - drain them`, drain queued wakes and handle them, then start exactly one fresh background task.
   When handling a wake ends the turn with a user-facing message or a decision prompt, re-arm BEFORE that message or prompt, not after, so a watcher stays live through the pause instead of leaving a blind gap; the guard only tolerates a re-arm already in flight, never one you still intend to start after the turn ends.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
9. If a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Claude background task mechanism.
10. Do not send idle progress while the watcher is parked.

Claude Code's background task completion is the wake mechanism.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified background arm wrapper.
Because the task's completion IS the wake, the arm ends only on information: a watcher wake reason, wake records waiting in the durable queue, or one bounded `FAILED`.
A watcher that dies with nothing to report is relaunched in place and never reaches you, and a second arm parks as a silent standby - it neither attaches to the live cycle nor exits - so one wake can only ever produce one notification.
[../incidents/watch-arm-notification-storm.md](../incidents/watch-arm-notification-storm.md) records what happened when it did not.
