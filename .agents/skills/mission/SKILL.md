---
name: mission
description: Plan and run a whole goal as a mission - decompose it into a judged task DAG under a mission container. Use when the user invokes /mission (e.g. "/mission migrate billing to v2 on Alpha") or hands you a whole multi-task goal to run end to end as one unit. Owns the mission decomposition, the independent plan judge, and the mission container at data/missions/<id>.md.
user-invocable: true
metadata:
  internal: true
---

# mission

A mission is a whole goal run as one unit: the captain hands over an end goal, and firstmate decomposes it into an ordered task DAG, plans it, and runs it toward production-ready.
Mission mode is being built in phases (see `docs/proposals/mission-mode.md`).
**This skill currently implements Phase 1: the judged planner.**
It decomposes the goal, has an independent judge critique the plan, gets the captain's confirmation, and materializes the mission and its DAG.
It then hands the tasks to the normal, captain-in-the-loop task lifecycle.
Autonomous dispatch, the adversarial review panel, mission-scoped auto-merge, and the Alpha integration-verification gate arrive in later phases; do not claim or perform them yet.

The mission-file contract - its format, id minting, scaffold, validation, and every write path - is owned by `bin/fm-mission.sh`; read its header with `bin/fm-mission.sh --help`.
Never hand-edit a file under `data/missions/`; every write goes through that script, the same way a direction goes through `bin/fm-direction.sh`.

## The Phase 1 procedure

1. **Resolve the project and read its direction.**
   Resolve the project from the goal exactly as intake does (`AGENTS.md` section 6), state it back, and read `data/directions/<project>.md`.
   The direction binds the whole plan: every task must move with it.

2. **Decompose, drafting the acceptance criteria.**
   Spawn a decomposer agent that, given the goal and the direction, produces two things:
   - **testable whole-goal acceptance criteria**, drafted from the goal - this is the mission's definition of done, and what the eventual Alpha integration-verification gate checks against;
   - an **ordered task DAG**: a set of tasks, each independently shippable and direction-aligned, with `blocked-by` edges expressing their order.
   Keep the plan within the mission's autonomy envelope (below); a plan that needs more tasks than the envelope allows is a signal to simplify or to raise the envelope deliberately, not to silently exceed it.

3. **Judge the plan independently.**
   Spawn a **separate** judge agent with a **fresh, clean context**: give it only the plan, the direction, and the drafted criteria - never the decomposer's reasoning - so it cannot rubber-stamp the decomposer's assumptions.
   The same harness is fine; the independence comes from the clean context.
   The judge critiques: do the tasks together satisfy every acceptance criterion, does any task fight the direction, are there missing or rogue tasks, are the `blocked-by` edges right?
   It returns PASS or FAIL with reasons.
   On FAIL, revise the decomposition against the critique and re-judge, up to a small cap (2 rounds); if it still fails, escalate the disagreement to the captain rather than shipping a plan the judge rejects.
   A direction conflict the project's standing-decisions ledger does not already settle is a captain escalation, not a judge call (`AGENTS.md` section 5, fork 3).

4. **Confirm with the captain.**
   Present the drafted acceptance criteria and the task plan (tasks, order, envelope) to the captain for edit and approval.
   Nothing is materialized until the captain approves; the criteria and plan are theirs to change.

5. **Materialize the mission and its DAG.**
   On approval:
   - `bin/fm-mission.sh new "<goal>" --repo <project> [--max-tasks N --max-spend N --max-hours N]` to mint the id and scaffold the container;
   - pipe the approved criteria into `bin/fm-mission.sh set-criteria <id>`;
   - for each planned task, create it in the backlog with its edges (`tasks-axi add <task-id> ... --blocked-by <id>`) and mirror it into the mission roster with `bin/fm-mission.sh add-task <id> <task-id> --blocked-by <id>`.
   `tasks-axi` is authoritative for the edges and each task's live state; the mission's Task DAG section is the membership roster so a recovered firstmate can reconstruct the mission from disk.

6. **Hand off to the normal lifecycle.**
   Phase 1 stops at the materialized plan.
   Dispatch each ready task, review, and route each PR to the captain through the project's normal delivery mode - exactly as any other ship task (`AGENTS.md` section 6).
   Report the mission id, the drafted-and-approved criteria, and the plan to the captain in plain outcomes.

## The autonomy envelope

Every mission carries one outer tripwire - total tasks, total spend, wall-clock - that catches a runaway *plan*.
The real guardrails are the direction, the review, and the tests; the envelope is only a backstop.
Defaults are conservative and per-mission overridable at `new` (see `bin/fm-mission.sh --help` and `docs/configuration.md`): 15 tasks, ~$50, 12 hours.
Set a higher envelope deliberately at the confirm step when the captain approves a genuinely large plan.
