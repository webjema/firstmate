---
name: stuck-crewmate-recovery
description: Agent-only playbook for stuck firstmate direct reports. Use after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer. Escalates from peek, to one-line steer, to harness-specific interrupt, to relaunch with progress, to failed status.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Load `harness-adapters` before sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then redirect with one corrective line.
   For example, for a single-Escape adapter: `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Escape`.
4. If the crewmate is genuinely wedged after redirection, exit the agent with the adapter's exit command and relaunch with the same brief plus a `progress so far` note appended to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the user with evidence.

## Autonomous adjudication (mission context)

When the stuck task belongs to a running mission, rung 5's dead-end at the captain is the wrong default: a mission is meant to run without a human in the loop, so it adjudicates the recovery itself first, under a mechanical hard cap.

Before each autonomous recovery attempt, check the cap: `bin/fm-recovery-ledger.sh tripped <id>` (default cap `FM_RECOVERY_CAP=3`).
If it prints `TRIP`, stop adjudicating and escalate to the captain as a batched digest with the evidence - the cap is enforced by the ledger, not by your own count, precisely so an autonomous loop cannot talk itself past its own limit.
Otherwise adjudicate the failure and pick one, then record it with `bin/fm-recovery-ledger.sh record <id> <action>`:

- **retry** - the failure looks transient or addressable (a flaky step, a missing detail): relaunch the crew with corrective guidance (rung 4), then re-review.
- **replan** - the task as scoped is the problem (wrong shape, a hidden dependency, an unbuildable acceptance criterion): abandon this attempt, take the finding back to the mission's planning pass to re-decompose that slice, and reset the ledger for the new task with `bin/fm-recovery-ledger.sh reset <id>`.
- **escalate** - the failure is destructive/irreversible/security-sensitive, a direction conflict the ledger of standing decisions does not settle, or otherwise beyond autonomous judgment: hand it to the captain immediately, regardless of the cap.

The cap counts `retry` and `replan` only; `escalate` is the terminal exit and never counts.
