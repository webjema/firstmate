# Incident: spawn forwarded credentials by typing them into the crew's pane

Date found: 2026-08-16.
Host: `/home/webjema/tools/firstmate2` (primary), Claude Code primary harness.
Script at fault: `bin/fm-spawn.sh`, in an uncommitted local change dated 2026-08-14 18:30 UTC.
Fixed by: the `forward_crew_credentials` file channel in `bin/fm-spawn.sh`, with `tests/fm-spawn-crew-env.test.sh`.

## Defect

A tmux window's shell inherits from the tmux server, not from the client that created it, so nothing firstmate exports reaches a crew's pane on its own.
The change closed that by forwarding eight variables with `spawn_send_text_line "$T" "export $var=$(shell_quote "${!var}")"`.

`spawn_send_text_line` resolves to `fm_backend_tmux_send_text_line`, which is `tmux send-keys`.
That TYPES the line into the pane, so the value lands in two durable places:

1. The pane's scrollback, which `bin/fm-peek.sh` reads directly into firstmate's context, and from there into a status line, a report, or a chat message.
   Firstmate operates under a standing never-print-a-secret rule, and this mechanism can violate it with nobody doing anything wrong.
2. The pane shell's history, which bash writes to `~/.bash_history` when the pane exits.
   Nothing in `bin/fm-spawn.sh` touches `HISTFILE` or `set +o history`.

The value was `shell_quote`d, so this was never a quoting or injection defect.
The escaping was correct and the delivery channel was wrong.
Quoting also makes the leak harder to detect, not safer: `shell_quote` rewrites an embedded `'` as `'\''`, so a naive grep for the whole secret misses a typed-but-quoted value that scrollback still renders perfectly readable.

## Measured

Presence-only checks; no value was ever printed or recorded.

| Fact | Evidence |
| --- | --- |
| Change was live from 2026-08-14 18:30 UTC | `stat -c '%y' bin/fm-spawn.sh` in the primary checkout |
| Every live task was spawned after that | oldest `state/*.meta` mtime was 2026-08-15 22:25 |
| Affected windows | `fm-transcript-arm-unrouted-v5`, `fm-spawn-creds-typed-into-pane-f4`, `fm-worktree-prepush-gate-absent-n7` |
| Of the eight vars, four were set | `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_VERTEX_PROJECT`, `GOOGLE_VERTEX_LOCATION`, `ASANA_ACCESS_TOKEN`; the four API-key vars were unset |
| Typed lines do reach `~/.bash_history` | 23 lines matching `GOTMPDIR` (the neighbouring typed export) in `~/.bash_history` |
| Non-secret vars already persisted there | 2 lines each matching `^export GOOGLE_APPLICATION_CREDENTIALS=`, `^export GOOGLE_VERTEX_PROJECT=`, `^export GOOGLE_VERTEX_LOCATION=` |
| The one live secret had NOT reached the history file yet | 0 lines matching `^export ASANA_ACCESS_TOKEN=` in `~/.bash_history` |
| The vars are not set by any shell profile | 0 matches in `~/.bashrc`, `~/.bash_profile`, `~/.profile` |
| The vars are not in the tmux server environment | `tmux show-environment -g` lists none of them |

`GOOGLE_APPLICATION_CREDENTIALS` is a filesystem path and the two `GOOGLE_VERTEX_*` vars are identifiers, so of the four, only `ASANA_ACCESS_TOKEN` is a secret value.

## Exposure that already exists

`ASANA_ACCESS_TOKEN` is in the scrollback of the three live panes above, and in those shells' in-memory history.
It has not reached `~/.bash_history` yet because those shells have not exited; killing their windows at teardown is what flushes it.

Remediation, in the order it should be done:

1. `tmux clear-history -t <session>:<window>` for each affected window, which tmux resolves to that window's active pane.
   It drops the saved scrollback that `capture-pane -p -S -N` reads, and it sends no keystroke into a pane running an agent TUI, so it is safe on a live crew.
   Verified present on this host: `tmux list-commands` reports `clear-history (clearhist) [-H] [-t target-pane]`.
2. Scrub `~/.bash_history` after the affected panes exit: `grep -vE '^export (ASANA_ACCESS_TOKEN|GOOGLE_APPLICATION_CREDENTIALS|GOOGLE_VERTEX_[A-Z]+)=' ~/.bash_history` into a temp file, then replace, preserving mode 600.
   The `^export` anchor is what keeps the user's own compound commands (`cd ... && export GOOGLE_APPLICATION_CREDENTIALS=...`) in the file; verified against a fixture rather than the real history.
3. Rotating `ASANA_ACCESS_TOKEN` is the only complete remediation, because steps 1 and 2 cannot prove the value was never read.
   That is the user's call, not an agent's, and it is the reason this file exists rather than a chat message.

## What the fix does not cover

It closes the spawn-time channel only.
The credential is still in the crew agent's shell environment, which is the point of forwarding it, so an `env`, a `printenv`, or a verbose tool error in that pane still writes the value into scrollback that `bin/fm-peek.sh` reads into firstmate's context.
Forwarding a secret to a crew cannot give a stronger guarantee than that.
So step 1 above is an ongoing habit before peeking a pane that has handled credentials, not a one-off cleanup for this incident.

## Why the fix is a file and not `tmux new-window -e`

Passing the environment at window creation was the other candidate.
It is worse on two counts.
`tmux new-window -e VAR=value` puts the value in the tmux client's argv, where any `ps` on the box reads it, including a `ps` run by a crewmate.
It would also push a secret into `bin/backends/tmux.sh`'s contract, where every future backend has to re-solve the same problem.

The file channel is backend-agnostic: values go to `<tasktmp>/crew-env.sh` created under `umask 077`, and only the path is typed.
`<tasktmp>` is `/tmp/fm-<id>`, which is outside every worktree, so the file cannot be staged, and `bin/fm-teardown.sh` removes it with the rest of the task temp root while `bin/fm-scratch-reap.sh` reaps orphans older than 24h.
