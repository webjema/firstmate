# Proposal: tending (incremental, tracked codebase and docs health)

Status: design signed off; Phase 1 (the shared engine) built.
Date: 2026-07-19.
Scope: two firstmate self-improvements over one shared engine, shipped through the normal branch to PR to captain-merge pipeline, one PR per phase.

Settled at sign-off: the skills are `/code-shape` and `/docs-sync`; both are captain-invoked only, never run on a schedule; a run is bounded by an estimated-token budget (default 25000, roughly 20-30k) rather than a unit count.

## 1. What this is

Tending is keeping a project in good shape as a bounded, tracked, repeatable pass rather than a one-shot audit.
It answers a problem every long-lived project has and firstmate has no answer for today: the codebase accretes duplication, dead code, and comment noise, and the docs drift out of sync with the code and with Asana, and nobody can review the whole project at once to catch it.

Tending is two skills over one shared mechanism.

- `/code-shape` keeps the codebase maintainable, testable, and free of duplication, with compact comments that explain why and nothing that references a throwaway work-in-progress doc.
- `/docs-sync` keeps the documentation true to the code and to Asana, with no half-implemented leftovers and no stale claims.

Both face the same hard problem - you cannot review a whole project in one pass - and both solve it with the same coverage ledger.
That ledger is the heart of this proposal; the two skills are thin briefs on top of it.

## 2. The contract (target behavior)

The captain invokes `/code-shape <project>` or `/docs-sync <project>`, or firstmate runs one on a cadence.
Firstmate resolves the project and reads its direction, then asks the ledger for the next slice to work.
The ledger picks a bounded slice using git history: it prefers a slice that changed since it was last reviewed, falls back to a never-reviewed slice when nothing changed, and never re-picks a slice that has not moved since its last clean pass.
Firstmate dispatches one crewmate scoped to that slice, which fixes what it finds and opens a PR - a direct-fix ship, not a report.
When the crew finds nothing to fix, it says so and no PR is opened.
Firstmate reviews the diff against the direction, relays it to the captain, and on merge records the slice as reviewed at the merge commit.
Because every pass is bounded and every slice is tracked, running the skill repeatedly makes steady progress with no wasted re-review and eventual full coverage.

`/docs-sync` adds one thing: an Asana reconciliation.
The crew reconciles docs against code, PRs, and Asana, and proposes an Asana change-set.
Firstmate relays the proposed Asana writes to the captain and applies them only on explicit confirmation, because writing to Asana is outward-facing.

## 3. The shared engine: the coverage ledger

The ledger is the reusable mechanism both skills stand on.
It is owned by one script, `bin/fm-review-ledger.sh`, the same way a direction is owned by `bin/fm-direction.sh` and a mission by `bin/fm-mission.sh`.
The skills never hand-edit it; every write goes through the script.

### Where it lives

Per project, per track, under the active firstmate home: `data/reviews/<project>/<track>.md`, where `<track>` is `codebase` or `docs`.
It is gitignored like the rest of `data/`, because what firstmate has and has not reviewed for the captain is the captain's operational record, not the project's.

### What a unit is

A unit is a reviewable slice of the project.
By default a unit is a top-level source directory, auto-derived so the skill works on any project with zero configuration.
A project whose default units are too coarse can override them per track with a units list at `data/reviews/<project>/<track>.units`, one git pathspec per line.
The `codebase` and `docs` tracks share this unit model and differ in the ledger they write and the brief the crew is given; a docs-centralized project points the `docs` track at its documentation tree through that override.

### What the ledger stores

One row per unit: the unit path, the commit SHA it was last reviewed at, the date of that review, and a one-line verdict (for example `clean` or `PR <url>`).
A never-reviewed unit has no row, or a row with an empty SHA.

### How selection works - the git-driven tier order

Selection is pure git against the stored SHA, which makes "touched since we last looked" a fact rather than a guess.
For each unit, `git log <last_reviewed_sha>..HEAD -- <unit>` is empty exactly when the unit has not moved since its last review.
The units partition into three tiers, and the tiers are exactly the captain's stated intent:

1. Changed since last review, ranked by recency and churn.
   This is "pay attention to something recently created".
2. Never reviewed, or reviewed longest ago, when tier 1 is empty or trivially small.
   This is "if nothing is recent or it is very small, review a new part not touched yet".
3. Unchanged since its last review - skipped.
   This is "do not review it again".

`select` prints the next slice and the one-line reason it was chosen.
Every pass is bounded by a unit count or a diff-size budget so one run is always cheap; the ledger guarantees repeated runs converge on full coverage.

### Robustness

The stored SHA can stop being an ancestor of HEAD after a history rewrite.
The ledger stores the review date alongside the SHA and falls back to `git log --since <date>` when the SHA is no longer reachable, so a rebase degrades selection gracefully instead of breaking it.
The script owns this fallback; the skills never reason about it.

### Verbs

- `select <project> <track>` - print the next slice and why, within the run budget.
- `record <project> <track> <unit> --sha <sha> --verdict <text>` - mark a unit reviewed.
- `status <project> <track>` - coverage and staleness overview across all units.

The script header and `--help` own the exact flags, defaults, and formats; this proposal does not restate them.

## 4. `/code-shape` - keeping the codebase in shape

1. Resolve the project and read its direction; the quality axis is what "good" means here.
2. Ask the ledger for the next slice.
3. Dispatch one direct-fix ship crewmate scoped to that slice, briefed to find and fix, within the slice:
   - duplication - similar functions across files merged into one universal function, or an overloaded function split into clear pieces;
   - maintainability and testability smells, and dead code;
   - comment hygiene - remove comments that reference throwaway work-in-progress docs or stale TODOs, and leave only compact comments that explain why, only where a reader a year from now needs them.
   The crew may read project-wide, because duplication lives across files, but is responsible only for the selected slice.
4. When the crew finds nothing worth changing, it reports the slice healthy and opens no PR.
5. Firstmate reviews the diff against the direction, relays it, and on merge records the slice.

The standing comment rule - no comments pointing at throwaway work-in-progress docs, compact and why-focused only - belongs in each project's quality direction as well, so `bin/fm-brief.sh` injects it into every brief.
The skill audits what the direction already mandates.

## 5. `/docs-sync` - keeping the docs true

1. Resolve the project and read its direction.
2. Ask the ledger for the next doc slice, on the `docs` track, preferring docs whose referenced code changed recently.
3. Dispatch one direct-fix ship crewmate scoped to that doc slice, briefed to:
   - reconcile every work-in-progress and implementation doc against merged PRs, commit history, and the actual code, classifying each claim as implemented, partial leftover, stale, or orphaned;
   - fix the docs - update, merge, or delete - so no leftover or stale claim survives;
   - produce an Asana change-set: which Asana tasks the code proves done and should close, and which are reopened or mismatched.
4. Firstmate reviews the docs diff against the direction and relays it.
5. Firstmate relays the proposed Asana writes separately and applies them via the Asana connector only on the captain's explicit confirmation; docs changes land as the crew's PR, Asana writes are firstmate's on confirmation.
6. On merge, record the doc slice.

The Asana relationship is bidirectional in what it reconciles - code and PRs and docs and Asana are cross-checked all ways - but every Asana write is captain-confirmed, never automatic.

## 6. Build phases

One PR per phase, each independently shippable, in this order so the hard part is de-risked first.

- Phase 1: the shared engine. Built.
  `bin/fm-review-ledger.sh` with `select`, `record`, `status`, and `units`, the auto-derived units with per-track override, the git-driven tier selection, the estimated-token budget, and the history-rewrite fallback; colocated tests at `tests/fm-review-ledger.test.sh`; the mechanism reference at `docs/review-ledger.md`.
- Phase 2: `/code-shape`. Built.
  The skill at `.agents/skills/code-shape/SKILL.md`, its `{TASK}` brief mandate, its trigger in the section 5 Quality subsection, and the offer to record the comment-hygiene rule into the project's quality direction.
- Phase 3: `/docs-sync`.
  The skill under `.agents/skills/docs-sync/`, the Asana reconciliation and captain-confirmed write path, its brief additions, and its section 13 trigger.

## 7. Resolved at sign-off

- Names: `/code-shape` and `/docs-sync`.
- Cadence: captain-invoked only; no self-scheduling.
- Run budget: an estimated-token cap, default 25000 (`FM_LEDGER_TOKEN_CAP`), rather than a unit count.

Deferred, not blocking: a smarter docs-track default that auto-derives units from a `docs/` tree instead of the shared top-level set; today a docs-centralized project uses the per-track override.
