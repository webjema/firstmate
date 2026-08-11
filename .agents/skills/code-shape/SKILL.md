---
name: code-shape
description: Run a fortnightly architect pass over a project - record the drift metrics, sweep the PRs merged since the last pass for architecture conformance, and turn what can be mechanized into checks rather than findings. Use when the user invokes /code-shape (e.g. "/code-shape acme") or asks whether a codebase is drifting, still matches its architecture, or is staying in shape. Produces a classified report; the checks it proposes ship as a separate PR on the captain's word.
user-invocable: true
metadata:
  internal: true
---

# code-shape

An architect pass asks a question no per-PR review can answer: *is this codebase still the one we designed, and which way is it moving?*
It is captain-invoked, intended fortnightly, and never runs on a schedule.

## What this pass is not

**It is not a second code review.** The project's own review already reads each diff for bugs before it lands, and re-reading the same diffs the same way is waste. This pass looks for what per-PR review structurally cannot see: a change that was individually fine and collectively wrong.

**It does not tidy code.** An earlier version of this skill dispatched a crew to fix whatever it found in a slice of the tree. Measured on optiroq 2026-08-10: of 16 slices reviewed, 13 came back `clean` and the product tree was never reached once - `api`, `features`, `allma-steps` and `packages` had never been looked at, while `.vscode` and `bin` had. A fix-oriented pass gravitates to whatever is small enough to finish. This one reports and mechanizes instead.

## The output that matters: a check, not a finding

**A pass that ships one lint rule beats a pass that files ten concerns.** The rule catches every future violation at authoring time, for free, forever; the concern decays into a backlog nobody drains.

This is not a preference, it is the observed difference between the two halves of a real codebase. Where optiroq mechanized an architectural invariant - `eslint.config.mjs` keeps `assistant/core` free of AWS and provider SDKs via `no-restricted-imports`, commented *"Enforced here, not by discipline"* - the boundary held. Where the same repo wrote the rule down in prose instead - AGENTS.md §9, "never call `axios` from components" - `src/portal-ui/src/features/profile/ProfileForm.tsx:11` imports axios today and no one noticed. Same repo, same authors, same year. The difference is which invariants got a mechanism.

So every finding is classified by what would prevent the *next* one:

- **Tier A - mechanize.** A checker could decide this. The deliverable is the rule, test, or CI check, not a description of the problem.
- **Tier B - judge.** It needs context a checker cannot have. The deliverable is a concern, for a human to accept or decline.
- **Tier C - watch.** It is a direction, not an event. The deliverable is a recorded number and its delta.

A pass whose report is all Tier B has usually not tried hard enough. Ask of each concern: *what would have caught this automatically?* Often the honest answer is "a five-line lint rule", and then it is a Tier A.

## Running a pass

### 1. Resolve the project and read its direction

Resolve the project from the invocation exactly as intake does (`AGENTS.md` section 6) and state it back.
Read `data/directions/<project>.md`: the quality axis is the standing answer to what "good" means here, and it binds what counts as a finding.

### 2. Record the drift metrics

```sh
bin/fm-code-metrics.sh record <project> --note "code-shape pass"
```

This appends a row and prints the delta against the previous pass. Its header owns the metric definitions; two notes on reading it:

- **`new_cmt%` is the leading indicator, `cmt%` is the lagging one.** On optiroq the tree average sat at 24% while newly written code was at 44% - a pass reading only the average would have reported nothing wrong. When the two diverge, the gap is the finding.
- **A metric never fails a pass.** There are no thresholds in the script on purpose. A number that moved is a question worth asking; whether it is drift or healthy growth is a judgment, and the direction (step 1) is what settles it.

The sha on the last row before this one is the window start for step 3. On a first pass there is none - use the last 14 days and say so.

### 3. Sweep the window's merged PRs for architecture conformance

List what landed since the window start and read the changes against what the project says about itself - its `AGENTS.md`, its architecture and domain docs, its existing lint and CI config. You are asking:

- **Does it obey the stated architecture?** The layering, the data path, the boundaries the project claims to have.
- **Does it obey a rule the project wrote down?** A prose rule with no enforcement is where drift starts; each violation found is a Tier A candidate, because the rule already exists and only the mechanism is missing.
- **Is a pattern spreading?** The second and third copies of a shape are the moment to decide it is the house style or stop it. Neither PR was wrong alone.
- **Did an escape hatch get used?** A suppression, a cast, a disabled check. One is a decision; a trend is a design problem.

Scope the depth to the window, not the tree. At optiroq's rate that is roughly 20 PRs a fortnight - readable in one pass. If the window holds far more, say so and sweep the largest changes rather than silently sampling.

**Read the code as the authority.** When the code and a doc disagree, the finding is usually that the doc is stale - *say so, and never write code to make a document true*. That inversion once shipped an invalid AWS resource that blocked a deploy pipeline for 23 hours (optiroq `documentation/security/05-api-cqrs-dispatchers.md`, OPTIROQ-SEC-05-001).

### 4. Report, classified and capped

Dispatch this as a **scout** (`AGENTS.md` sections 6 and 7) - the deliverable is knowledge, and it ends at `data/<id>/report.md`, never a PR. The report carries:

- The metric deltas from step 2, with one line on each that moved and whether it reads as drift or growth.
- **At most 8 findings**, ranked by what they cost if left. A capped list gets read; a complete list gets skimmed. Say how many were dropped.
- Each finding: one-line claim, a `file:line`, its tier, and for a Tier A **the actual rule** - the ESLint config, the test, the CI step. A Tier A without a draft check is a Tier B wearing a costume.

### 5. Ship the checks, record the concerns

Tier A items the captain accepts become one **ship** task, scoped to adding the checks and fixing whatever they now flag. This is the only code this pass causes to change, and it lands through the project's normal delivery mode.

Tier B concerns go to `data/reviews/<project>/concerns.md`, one row each:

```
| id | date | severity | claim | where | state |
```

`state` is `open`, `declined`, or `fixed`. **A declined concern is never raised again** - re-litigating a decision the developers already made is how a report stops being read. Before writing a new concern, check the file: if the same claim is there as `declined`, drop it, and only revive it with new evidence, saying what changed.

### 6. Close the pass

The metrics row from step 2 is the record - its sha is the next pass's window start, so no separate ledger is needed. If the ship task from step 5 lands after the pass, that is fine; the window is defined by the measurement, not by the fix.

## Cadence and drift between passes

Fortnightly fits a project merging ~20 PRs in that time: long enough that a trend is visible, short enough that the window is readable. A project moving faster wants a weekly pass with the same cap, not a fortnightly pass with a longer list.

Nothing here is scheduled. If the user wants it recurring, that is `/loop` or a routine, and they must ask for it.
