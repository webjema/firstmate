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
**This skill currently implements Phases 1-3: the judged planner, the autonomous dispatcher with the adversarial review panel, and mission-scoped auto-merge under the envelope.**
Phase 1 (Planning, below) decomposes the goal, has an independent judge critique the plan, gets the captain's confirmation, and materializes the mission and its DAG.
Phase 2 (Running the mission, below) then drives the DAG itself: it dispatches ready tasks, gates each one at an adversarial review panel, and advances dependents as tasks land.
Phase 3 grants merge authority: a task that survives the review panel and goes green on CI is **merged to `main` by the mission itself**, bounded by the envelope and mechanically red-safe (`bin/fm-pr-merge.sh` refuses a red PR).
**Production is always a human hard-stop:** the mission merges to `main` and (in a later phase) deploys to Alpha, but never promotes to production - that stays the captain's.
The Alpha integration-verification gate and autonomous recovery adjudication arrive in a later phase; do not claim or perform them yet.

The mission-file contract - its format, id minting, scaffold, validation, and every write path - is owned by `bin/fm-mission.sh`; read its header with `bin/fm-mission.sh --help`.
Never hand-edit a file under `data/missions/`; every write goes through that script, the same way a direction goes through `bin/fm-direction.sh`.

## Planning the mission (Phase 1)

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

6. **Confirm the plan is materialized, then run it.**
   Report the mission id, the drafted-and-approved criteria, and the plan to the captain in plain outcomes, then proceed to Running the mission.

## Running the mission (Phase 2)

Once the DAG is materialized, firstmate drives it. Keep exactly one live supervision cycle throughout (`AGENTS.md` section 7); the mission runs on the same watcher, wakes, and teardown as any other work.

1. **Dispatch the ready frontier.**
   The dispatchable set is the mission's roster intersected with the backlog's ready frontier: the members from `bin/fm-mission.sh tasks <id>` that also appear in `tasks-axi ready`.
   Spawn those as ship tasks (batch spawn, `AGENTS.md` section 6), with each crew's brief carrying the mission's acceptance criteria as its frame.
   This script deliberately does not read tasks-axi state; firstmate does the intersection.

2. **Hold the envelope.**
   Before spawning, check the mission's autonomy envelope (below).
   If dispatching would push the mission past its task, spend, or wall-clock ceiling, do NOT dispatch: pause the mission and escalate a batched digest naming which ceiling and by how much.
   The envelope only catches a runaway plan; a healthy plan never reaches it.

3. **Gate each task at the adversarial review panel.**
   When a crew signals review-ready, do NOT rubber-stamp it.
   Read the pushed diff with `bin/fm-review-diff.sh <id>`, then spawn a panel of independent skeptics (default 3), each with a fresh, clean context, each prompted to REFUTE the change on a distinct lens: does it actually satisfy every acceptance criterion, does it fight the direction, does it introduce a regression?
   Default a verifier to "refuted" when it is unsure.
   Majority-refute means the change is rejected: relay the refutations to the crew to fix in place (`bin/fm-send.sh`), then re-review.
   Only a change that survives the panel is approved: the crew opens the PR, and the mission proceeds to auto-merge it (next step).

4. **Probe mid-flight for confidently-wrong work.**
   Every health signal firstmate has keys on liveness and motion, so a crew building the WRONG thing reads as perfectly healthy - this is the hardest failure mode.
   While a crew is working, periodically sample its current diff (`bin/fm-review-diff.sh <id>`) against its brief and the mission's acceptance criteria with a fresh agent, to catch drift before it reaches review-ready.
   On a drift finding, steer the crew (`bin/fm-send.sh`) or, if it is off-plan, escalate.

5. **Cap the churn.**
   Cap review-fix rounds per task (default 3) and per-task relaunches.
   On a trip, stop re-running the loop: escalate that task to the captain as a batched digest rather than churning tokens on a task that will not converge.

6. **Auto-merge when green, then advance.**
   Arm each approved PR's poll with `bin/fm-pr-check.sh` so its CI result wakes firstmate.
   When the poll reports the PR green (checks passed, waiting on merge), merge it with `bin/fm-pr-merge.sh <id> <pr-url>` - never `gh pr merge` directly.
   The merge is mechanically red-safe: `fm-pr-merge.sh` reads the CI rollup and refuses a red PR, so a mission can never land failing work; a checks-failed wake instead routes the task back through the fix loop and the round cap.
   Post a one-line "merged <full PR URL>" FYI so the captain keeps a trail, exactly as a yolo merge does (`AGENTS.md` section 5).
   On the resulting `check: merged` wake, tear the crew down, recompute the rollup from tasks-axi state and write it with `bin/fm-mission.sh set-rollup <id>`, then re-run the dispatch loop (step 1): the merge cleared blockers, so newly-ready members now dispatch.

7. **Stop when the DAG is landed.**
   When every roster member is landed, the mission's plan is complete.
   Report to the captain and stop; the Alpha deploy, the integration-verification gate, and the held production promotion are a later phase.

**Hard stops (always pause and escalate as a batched digest, never proceed):** a production deploy or promotion, an envelope trip, a task that will not converge past the round cap, anything else destructive/irreversible/security-sensitive, and a direction conflict the project's standing-decisions ledger does not already settle (`AGENTS.md` section 5, fork 3).
Mission auto-merge reaches `main` only; it never merges outside the mission's own tasks, and it never promotes to production.

## The autonomy envelope

Every mission carries one outer tripwire - total tasks, total spend, wall-clock - that catches a runaway *plan*.
The real guardrails are the direction, the review, and the tests; the envelope is only a backstop.
Defaults are conservative and per-mission overridable at `new` (see `bin/fm-mission.sh --help` and `docs/configuration.md`): 15 tasks, ~$50, 12 hours.
Set a higher envelope deliberately at the confirm step when the captain approves a genuinely large plan.
