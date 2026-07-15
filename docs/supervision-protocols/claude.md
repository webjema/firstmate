Mode: Claude background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Run `bin/fm-watch-arm.sh` as its own Claude Code background task.
3. Never bundle the arm command with other commands.
4. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.claude/settings.json`.
5. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
   On attach, the background task stays live until that existing cycle ends; it does not exit immediately.
6. Treat `watcher: FAILED - no live watcher with a fresh beacon` as an alarm and repair it before ending the turn.
7. When the background task completes with `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes and handle them, then start exactly one fresh background task.
   When handling a wake ends the turn with a user-facing message or a decision prompt, re-arm BEFORE that message or prompt, not after, so a watcher stays live through the pause instead of leaving a blind gap; the guard only tolerates a re-arm already in flight, never one you still intend to start after the turn ends.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
8. If a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Claude background task mechanism.
9. Do not send idle progress while the watcher is parked.

Claude Code's background task completion is the wake mechanism.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified background arm wrapper.
Re-arm attaches to an existing healthy cycle when one is already present, so the background task stays live until that cycle ends.
