# Proposal: mission mode (full-autonomy end-to-end crew management)

Status: proposed, awaiting captain sign-off.
Date: 2026-07-18.
Scope: a firstmate self-improvement, shipped through the normal branch to PR to captain-merge pipeline, one PR per phase.

## 1. What this is

Mission mode is a mode where the captain hands firstmate a whole goal and firstmate runs crews end to end with no human in the loop.
It decomposes the goal into an ordered task DAG, dispatches it, monitors and reviews each crew, merges mechanically-safe work to `main`, deploys to Alpha, and runs a whole-goal integration verification against the live Alpha deploy, then stops and holds the production promotion for the captain.

Mission mode is not a new engine bolted on beside firstmate.
It is the composition of two levers firstmate already has, plus the connective tissue and safety gates that neither lever supplies on its own.

- `yolo` is the authority lever: it lets firstmate make approval decisions itself instead of asking, but only per-merge, and only inside an interactive session.
- `afk` is the self-driving lever: its daemon self-handles routine wakes and batches escalations, but it explicitly refuses to change approval authority.

Mission mode raises `yolo` from per-merge to whole-goal, gives it `afk`'s self-driving loop, and adds the missing pieces: a goal container, a decomposition producer, an auto-dispatcher, a confidently-wrong backstop, semantic-loop and cost ceilings, a mechanically red-safe merge, autonomous recovery adjudication, a production-readiness gate, and a ledger-first direction-conflict policy.

## 2. The contract (target behavior)

The captain gives a goal.
Firstmate runs a judged planning pass: it decomposes the goal into a task DAG, then an independent agent critiques the plan against the project direction and the whole-goal acceptance criteria before any crew ships.
Firstmate auto-dispatches the DAG, advancing dependents as each blocking task merges.
Each crew's finished work passes an adversarial review panel that checks acceptance criteria, direction, and regression, and is not a rubber stamp for the crew's own review.
Mechanically red-safe work merges to `main`.
A direction conflict resolves from the project's standing-decisions ledger if the ledger already answers it, and otherwise pauses and escalates, writing back every novel resolution so the same conflict never pauses twice.
When the DAG is fully landed, firstmate auto-deploys to Alpha and runs a whole-goal integration verification against the live Alpha deploy.
Then it stops, holding the production promotion for the captain.

A bounded hard-stop set always pauses and escalates as a batched digest rather than proceeding.

## 3. Core objects

### Mission

A mission is the goal container that firstmate lacks today.
It is started conversationally with the `/mission` skill, which drives the `bin/fm-mission.sh` engine that owns the mission-file contract, the same way `/direction` sits over `bin/fm-direction.sh`.
Its id is a kebab slug with a random suffix, exactly like a task id.
It lives at `data/missions/<id>.md` under the active firstmate home, gitignored like the rest of `data/`, because a goal and its acceptance criteria are the captain's, not the project's.
It carries:

- the end goal, in the captain's words;
- the whole-goal acceptance criteria that define done for the mission, distinct from any single task's definition of done;
- the task DAG, as an ordered set of task ids with their blocked-by edges;
- the autonomy envelope, the outer tripwire values for this mission;
- a live completion rollup, updated as tasks land, so a recovered firstmate can reconstruct mission state from disk alone.

The mission file is the mission's single source of truth, the same way `state/<id>.meta` is a task's.
A mission never lives only in conversation memory.

### The DAG

The DAG is expressed with the task primitives firstmate already has, not a new graph store.
`tasks-axi add --blocked-by <id>` records an edge, `tasks-axi ready` lists the currently-dispatchable frontier, and `tasks-axi block` / `unblock` adjust edges.
A mission is therefore a set of tasks tagged to one mission id, wired with blocked-by edges, plus the mission file that holds the goal-level material the task backend does not model.

### The autonomy envelope

The envelope is deliberately thin, per the captain's aggressive-runaway decision.
The real guardrails are the direction axes, the adversarial review panel, and the tests.
The envelope adds exactly one outer absolute tripwire per mission, to catch a runaway plan rather than to second-guess a healthy one:

- a total-task ceiling;
- a total-spend ceiling;
- a wall-clock ceiling.

The defaults are conservative so an early trip is cheap: 15 total tasks, roughly $50 total spend, and 12 hours wall-clock.
They are per-mission overridable at start (for example `--max-tasks 40`) and can be raised at the pause when a trip asks.
Any trip pauses the mission and escalates a batched digest.
Per-task ceilings (review-fix rounds, relaunches) live at the task level and are separate from the mission envelope.

## 4. The nine gaps and how mission mode closes each

1. No goal or epic container.
   Closed by the Mission object in section 3.
2. No decomposition producer.
   Closed by the judged planning pass: a decomposition step that also drafts the whole-goal acceptance criteria from the captain's goal, followed by an independent plan-vs-direction judge that must pass before any crew ships.
   The captain edits and approves the drafted criteria and plan at a confirm step before anything runs.
   The judge is a separate spawned agent with a fresh, clean context: it sees the plan, the direction, and the criteria, but not the decomposer's reasoning, so it cannot rubber-stamp the decomposer's assumptions.
   A different harness is not required; the independence comes from the clean context, and a cross-harness judge can be added later if a real blind spot appears.
3. No auto-dispatcher.
   Closed by a dispatch loop that reads `tasks-axi ready`, spawns each dispatchable task, and on each `check: merged` wake spawns the now-unblocked dependents.
4. Confidently-wrong work is undetectable.
   This is the hard gap: every existing health signal keys on liveness and motion, so a crew building the wrong thing reads as perfectly healthy.
   Closed by an adversarial verifier panel at each `review-ready`, plus a mid-flight diff-vs-brief probe that catches drift before the crew finishes.
5. No semantic-loop or cost ceiling.
   Closed by a per-task cap on review-fix rounds and relaunches, plus the per-mission envelope; any trip pauses and escalates.
6. "Never a red PR" is enforced by awareness, not by the merge script.
   Closed by moving the CI-rollup check into `bin/fm-pr-merge.sh`, so autonomy mechanically cannot merge red.
7. Recovery dead-ends at the human.
   The stuck-crewmate ladder's last rung is "tell the captain"; under autonomy that stalls the mission.
   Closed by an autonomous adjudication rung before that escalation: retry-with-guidance, abandon-and-replan, or escalate, hard-capped so it cannot loop.
8. No production-readiness gate.
   Closed by the Alpha integration-verification task that runs against the live Alpha deploy once the DAG is landed.
9. Direction conflicts require a human.
   Closed by the ledger-first policy in section 5, fork 3.

## 5. Decided forks (not open for re-litigation)

These three were decided by the captain and are fixed inputs to this design.

1. Ship authority.
   Mission mode auto-merges to `main` and auto-deploys to Alpha only, never to production.
   Production promotion is a human hard-stop.
   The end-of-mission integration-verification gate runs against the live Alpha deploy, and that is the production-ready testing step.
2. Runaway envelope: aggressive.
   The direction axes, the adversarial review panel, and the tests are the real guardrails.
   Keep only one outer absolute tripwire (total tasks, total spend, wall-clock) to catch a runaway plan.
3. Direction conflict: ledger-first.
   Resolve a direction conflict from the project's standing-decisions ledger if it already answers the question.
   Otherwise pause and escalate.
   Every novel resolution is written back with `bin/fm-direction.sh add-decision`, so the ledger compounds and the same conflict never pauses twice.

## 6. Safety and escalation

Mission mode never removes a hard-stop; it batches them.

The bounded hard-stop set always pauses the mission and escalates as a batched digest:

- a production deploy or promotion;
- anything destructive, irreversible, or security-sensitive;
- a budget or envelope trip;
- an unrecoverable failure, after the autonomous adjudication rung is exhausted.

Escalation etiquette follows the existing rule: outcomes in plain language, no firstmate internals, batched into a digest rather than a stream of pings, exactly as `afk` already does.
Away-mode approval authority is unchanged by mission mode; mission mode is its own authority grant, made explicit when the captain starts a mission.

## 7. Reuse map

Mission mode reuses the following, each verified to exist at proposal time.
It does not reinvent any of them.

- `yolo` authority lever and its carve-outs: `bin/fm-project-mode.sh`, `AGENTS.md` section 5.
- `afk` self-driving daemon and batched escalation: `bin/fm-supervise-daemon.sh`, the `/afk` skill.
- Watcher fat-payload wake vocabulary, durable queue, and liveness oracle: `bin/fm-watch.sh`, `bin/fm-classify-lib.sh`, `bin/fm-wake-drain.sh`, `bin/fm-supervision-live.sh`.
- Task DAG primitives: `tasks-axi add --blocked-by` / `block` / `ready`, batch spawn (`bin/fm-spawn.sh id=repo ...`), two-phase teardown with landed-work safety (`bin/fm-teardown.sh`).
- Event-driven advancement hook: `bin/fm-pr-check.sh` generates a per-task check that wakes firstmate on CI-fail or merge, which is the natural DAG-advance trigger.
- Direction-aware pre-merge review: `bin/fm-review-diff.sh`, which reviews the real PR head.
- Safe merge: `bin/fm-pr-merge.sh` (record-before-merge, plain gh), `bin/fm-merge-local.sh` (fast-forward).
- Direction and ledger: `bin/fm-direction.sh` (four axes plus `add-decision`).
- Scout-to-ship promotion in place: `bin/fm-promote.sh`.

## 8. Phasing

Each phase is its own PR the captain merges.
The build does not happen all at once, and merge authority is not granted before Phase 3.

1. Mission object and judged decomposition.
   Introduces the Mission object and the judged planning pass.
   Still hands each resulting PR to the captain; no merge authority yet.
   This proves the planner at the lowest risk and the highest value.
2. Auto-dispatcher and adversarial review panel.
   Drives the DAG from the ready-frontier and advances dependents on each merge.
   The adversarial review panel is the confidently-wrong backstop from gap 4.
3. Merge-gate hardening and mission-scoped auto-merge under budget.
   Moves the CI-rollup check into the merge script so red cannot be merged, then grants mission-scoped auto-merge authority bounded by the envelope.
4. Alpha integration-verification gate and autonomous recovery adjudication.
   Adds the production-readiness gate against the live Alpha deploy and the autonomous adjudication recovery rung.

## 9. Phase 1 scope (this PR series starts here)

Phase 1 delivers the Mission object and the judged decomposition, and nothing downstream of it.

In scope for Phase 1:

- `bin/fm-mission.sh`, the engine that owns the `data/missions/<id>.md` format, mints the mission id, and owns scaffold, read, validation, and rollup, in the shape of `bin/fm-direction.sh` (one owner for the contract, header owns the mechanics);
- a `/mission` skill that is the chat entry point and drives `bin/fm-mission.sh`, drafting the acceptance criteria and plan and showing them to the captain for edit and approval;
- a decomposition step that turns a goal into a set of tasks with blocked-by edges, drafts the whole-goal acceptance criteria, and writes the mission file;
- an independent plan-vs-direction judge, a separate agent with fresh context, that critiques the decomposition against the project direction and the drafted acceptance criteria and must pass before any crew ships;
- colocated tests under `tests/` named `<subject>.test.sh`, extending the existing runner pattern;
- a one-line-trigger addition to `AGENTS.md` for the `/mission` skill, kept to the size discipline, with detail routed to the skill and this doc.

Explicitly out of scope for Phase 1:

- any auto-dispatch, auto-merge, or auto-deploy;
- the adversarial review panel;
- any change to merge authority.

Phase 1 still routes every resulting PR to the captain through the normal review-and-merge flow.

## 10. Resolved decisions

These four were open at proposal time and resolved with the captain on 2026-07-18.

- Entry point and id: a mission is started conversationally with a `/mission` skill that drives a `bin/fm-mission.sh` engine; the mission id is a kebab slug with a random suffix, like a task id.
- Acceptance criteria: the decomposition step drafts testable whole-goal acceptance criteria from the captain's goal, and the captain edits and approves them at a confirm step before anything runs.
- Envelope: conservative, per-mission overridable defaults of 15 total tasks, roughly $50 total spend, and 12 hours wall-clock, raisable at start or at a trip.
- Judge independence: the plan-vs-direction judge is a separate spawned agent with a fresh, clean context (plan, direction, and criteria only, not the decomposer's reasoning); the same harness is acceptable, and a cross-harness judge is a later option, not a requirement.
