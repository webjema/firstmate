---
name: code-shape
description: Run a bounded, tracked tending pass that keeps a project's codebase in good shape - maintainable, testable, free of duplication, with compact why-only comments. Use when the user invokes /code-shape (e.g. "/code-shape acme") or asks to clean up, deduplicate, or improve the health of a project's code. Selects the next slice with the review ledger, ships a direct-fix crew scoped to it, and records the slice as reviewed on merge.
user-invocable: true
metadata:
  internal: true
---

# code-shape

A tending pass keeps a codebase in shape a bounded slice at a time, so a large project stays maintainable without anyone ever reviewing the whole thing at once.
The scoping, tracking, and prioritization are the review ledger's job (`bin/fm-review-ledger.sh`, narrated in `docs/review-ledger.md`); this skill turns the ledger's chosen slice into one direct-fix ship and records the result.
It is captain-invoked only; it never runs on a schedule.

## Running a pass

1. **Resolve the project and read its direction.**
   Resolve the project from the invocation exactly as intake does (`AGENTS.md` section 6) and state it back.
   Read `data/directions/<project>.md`: the quality axis is the standing answer to what "good" means here, and it binds every change this pass makes.

2. **Ask the ledger for the next slice.**
   Run `bin/fm-review-ledger.sh select <project> codebase` and read the chosen unit(s), the reason each was chosen, and the head sha.
   `NOTHING_TO_REVIEW` means the codebase is fully covered and quiet: say so and stop.
   Run `bin/fm-review-ledger.sh select <project> codebase --paths` to get the exact paths to scope the crew to.
   Do not second-guess the selection; the ledger already prefers recently-changed code and falls back to never-reviewed code, within the run's token budget.

3. **Dispatch one direct-fix ship crew scoped to the slice.**
   Scaffold a ship brief (`bin/fm-brief.sh <id> <project>`), then replace `{TASK}` with a code-shape task that says, in the crew's own delivery terms:
   - **Scope.** Improve the shape of the paths from step 2, and only those. You may read anywhere in the project - duplication lives across files - but change only the slice.
   - **What to fix.** Work the tending targets on the slice, highest-leverage first:
     - *Duplication* - merge near-identical functions into one clear function or split an overloaded one, extracting a shared helper only when the duplication is real and repeated (the rule of three) rather than to fuse a coincidental pair, and placing the extracted code where it naturally belongs rather than reaching across the slice boundary for a new home.
     - *Structure and testability* - the smells that make code hard to change or test: long functions, deep nesting, mixed I/O and logic, hidden dependencies and globals, primitive obsession, and names that do not say what they mean.
     - *Dead code* - unreachable branches, unused functions and exports, and commented-out code, removed rather than left to rot.
     - *Comments* - keep only compact comments that explain *why* (an invariant, a workaround, a non-obvious reason a reader a year from now will need); delete comments that merely restate what the code plainly does, point at throwaway work-in-progress docs, or are stale TODOs; correct or delete a comment that has gone wrong rather than leave it, because a wrong comment is worse than none; and never strip docstrings, public-API documentation, or license headers in the name of hygiene.
   - **How to change it safely.** Every change moves with the quality direction above, and the following bound the work:
     - *Pure refactor* - behavior stays identical, with no feature work, performance changes, or bug fixes folded in, and a real bug you find is surfaced as a finding rather than quietly fixed inside a cleanup diff where no reviewer will see it.
     - *Tests are the net* - the suite stays green, but a green suite only protects code the tests actually reach, so confirm a unit is covered before refactoring it, and if it is not, add characterization tests first or leave that code untouched and say why.
     - *Reviewable diff* - keep changes semantic in small logical commits, with no mass reformatting or wholesale renaming mixed in, which buries the real change and destroys `git blame`.
   - **A clean slice is a valid outcome.** If the slice is genuinely healthy, do not manufacture churn: report it clean and open no PR.
   Then spawn and supervise as any ship task (`AGENTS.md` sections 6 and 7): this is a normal direct-fix ship, reviewed against the direction before it lands, merged on the captain's word.

4. **Record the slice on the ledger when the pass ends.**
   After the crew's PR merges (sync the clone first, `AGENTS.md` section 7), record each unit from step 2 at the landed commit:
   `bin/fm-review-ledger.sh record <project> codebase <unit> --sha <merged-sha> --verdict <full-PR-url>`.
   For a slice the crew reported clean, record each unit at the current clone head with `--verdict clean` - a clean pass still counts as reviewed, so the ledger does not re-offer it until it next changes.
   Recording is what makes the next pass pick up new ground instead of the same slice.

## The comment rule belongs in the direction too

The comment-hygiene bar this pass enforces (step 3) is a standing quality principle, not a one-pass whim.
When a project's quality direction does not already carry it, offer to record it once with `bin/fm-direction.sh add-decision <project> "..."` (via `capture-decision`), so `bin/fm-brief.sh` injects it into every brief and every crew holds the line, not just a code-shape pass.
