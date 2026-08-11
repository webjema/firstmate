# The review ledger

`bin/fm-review-ledger.sh` is the coverage ledger `/docs-sync` stands on.
`/code-shape` used it too until 2026-08-11 and no longer does: its window is now the PRs merged since the last recorded metrics row, so coverage falls out of the fact that every line enters through a PR, and no slice ledger is needed. What that pass found wrong with slice selection is worth knowing before reusing this for a third track - see the note at the end.
It exists to make "review a project a bounded slice at a time, track what was reviewed, and never re-review an unchanged slice" a mechanism rather than a judgment the agent has to re-derive every pass.
The script header and `--help` own the exact verbs, flags, paths, and file format; this doc narrates the mechanism and the reasoning, the way `docs/architecture.md` narrates the watcher.

## Units - what a slice is

A unit is a reviewable slice of a project.
By default a unit is each top-level tracked directory, plus one synthetic `<root>` unit covering the top-level tracked files, so a project's `README` and root configs are never orphaned from coverage.
Units are auto-derived so a tending pass works on any project with zero configuration.
A project whose default units are too coarse - or a docs track that should point at a documentation tree instead of the source tree - overrides them per track with `data/reviews/<project>/<track>.units`, one git pathspec per line.

The two tracks, `codebase` and `docs`, share this unit model.
They differ in the ledger they write (`codebase.md` versus `docs.md`) and in the brief the crew is given, not in how the project is partitioned.

## Selection - the git-driven tier order

Selection is pure git against the commit each unit was last reviewed at, which turns "touched since we last looked" into a fact instead of a guess.
For a unit last reviewed at `sha`, `git rev-list --count <sha>..HEAD -- <unit>` is zero exactly when the unit has not moved since.
Units fall into three tiers, which are exactly the intent behind the skills:

1. Changed since its last review - ranked by most recent commit date, then by churn.
   This is "pay attention to something recently created".
2. Never reviewed - ranked by most recent commit date.
   This is "review a part not touched yet" when nothing recent is waiting.
3. Unchanged since its last review - dropped.
   This is "do not review it again".

The candidate list is tier 1 followed by tier 2; tier 3 units are never offered.
When every unit is tier 3, `select` prints `NOTHING_TO_REVIEW` and exits zero: the project is fully covered and quiet, not broken.

## Budget - why a run stays bounded

A run is capped by an estimated token count (`FM_LEDGER_TOKEN_CAP`, default 25000), estimated as the slice's source bytes divided by four.
`select` greedily walks the candidate list in priority order and stops before a unit that would push the run over the cap.
Because tier 1 comes first, a run spends its budget on recent work and only spills into never-reviewed units when recent work does not fill it - which is precisely "if nothing is recent, or it is small, review a new part".
At least one unit is always selected; a single unit larger than the whole cap is selected alone and flagged `OVERSIZED` so the crew sub-scopes it rather than the ledger silently dropping it.

## Robustness - surviving a history rewrite

A stored sha stops being an ancestor of `HEAD` after a rebase or a squash.
When `git merge-base --is-ancestor` shows the recorded sha is no longer reachable, selection falls back to the recorded date with `git log --since`, so a rewritten history degrades selection to a date heuristic instead of breaking it.
The ledger stores both the sha and the date for exactly this reason.

## Recording and coverage

`record` marks a unit reviewed at a sha with a one-line verdict - a PR url when a fix landed, or `clean` when the slice needed no change - replacing any prior row for that unit and keeping the file sorted for stable diffs.
A skill records each unit at the merge commit after its fix lands, so the reviewed slice reads as quiet on the next pass.
`status` prints per-unit coverage and flags any ledger row whose unit no longer exists as `ORPHAN`, so a renamed or deleted directory does not rot the ledger unnoticed.

The ledgers live under `data/reviews/<project>/`, gitignored like the rest of `data/`, because what firstmate has reviewed for the user is the user's operational record, not the project's.

## What selection got wrong - still live for the `docs` track

`/code-shape` stopped using this ledger because in a year of use it never once reached the code that mattered. Measured on optiroq 2026-08-10: 16 units reviewed, 13 verdicts `clean`, and the twelve *smallest* units in the project were all covered while `api` (27x the budget), `packages` (32x), `allma-steps` (23x) and `features` (20x) had never been looked at. Of the two over-budget units that ever got through, both produced a real fix; of the fourteen within budget, one did.

Three mechanisms produced that, and **`/docs-sync` still stands on all three**:

1. **Never-reviewed is last, not second.** This doc said tier 2 above; the code emits `changed`=1, `expired`=2, `never`=3. Tier 1 is "already reviewed and has since changed", which in a live repo is never empty - so reviewing a unit promotes it ahead of everything unreviewed, permanently.
2. **The budget fill is a smallest-first knapsack.** `cmd_select` uses `continue`, not `break`: after the first pick it keeps scanning and collects whatever still fits under the cap. Anything large is skipped on every pass forever.
3. **A unit larger than the whole cap is handed to the crew flagged `OVERSIZED` with "sub-scope it"** - a vague instruction at exactly the moment the slice is hardest.

The fix, if this is ever reused for a third track: split an over-cap unit into its children recursively so no unit is ever oversized, drain the never-reviewed backlog before re-offering covered ground, and turn that `continue` into a `break`. None of it is done - the `docs` track is running on the ledger as described in the rest of this file.
