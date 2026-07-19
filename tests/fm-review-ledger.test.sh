#!/usr/bin/env bash
# Tests for bin/fm-review-ledger.sh: the coverage ledger that lets a tending pass
# review a project one bounded, git-scoped slice at a time.
#
# The load-bearing behaviors:
#   (a) auto units are the top-level tracked dirs plus a <root> unit for top-level
#       files, and an override file replaces them
#   (b) a never-reviewed project selects its units (tier 2), within the budget
#   (c) recording a unit as clean makes select SKIP it while it stays unchanged
#   (d) a unit changed since its review jumps ahead of never-reviewed units
#   (e) the token budget bounds a run to a subset, but always at least one unit
#   (f) --paths expands the <root> unit to its actual files, for brief injection
#   (g) an unreachable recorded sha (history rewrite) falls back to the date, so a
#       rebase degrades selection instead of breaking it
#   (h) select reports NOTHING_TO_REVIEW when every unit is covered and unchanged
#   (i) status reports coverage and flags a ledger row whose unit is gone (ORPHAN)
#   (j) record replaces a unit's prior row rather than duplicating it
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER="$ROOT/bin/fm-review-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-ledger-tests)

gitc() { git -C "$1" -c user.name=t -c user.email=t@e.x "${@:2}"; }

# make_home <name> builds a home with a project clone "acme" carrying the
# top-level dirs src/, api/, docs/ and a top-level README.md, one commit.
make_home() {
  local name=$1 home repo
  home="$TMP_ROOT/$name"
  repo="$home/projects/acme"
  mkdir -p "$repo/src" "$repo/api" "$repo/docs" "$home/data"
  printf 'a\n' > "$repo/src/a.js"
  printf 'b\n' > "$repo/api/b.js"
  printf 'g\n' > "$repo/docs/g.md"
  printf '# readme\n' > "$repo/README.md"
  git -C "$repo" init -q
  gitc "$repo" add -A
  gitc "$repo" commit -qm init
  printf '%s\n' "$home"
}

run() {
  local home=$1; shift
  FM_HOME="$home" "$LEDGER" "$@"
}

head_of() { git -C "$1/projects/acme" rev-parse HEAD; }

# (a) ------------------------------------------------------------------------
test_auto_units_and_override() {
  local home out
  home=$(make_home units)
  out=$(run "$home" units acme codebase)
  assert_contains "$out" 'src' "units: top-level dir src"
  assert_contains "$out" 'api' "units: top-level dir api"
  assert_contains "$out" '<root>' "units: synthetic root unit for top-level files"

  # An override file replaces the auto set verbatim (comments/blanks ignored).
  mkdir -p "$home/data/reviews/acme"
  printf '# just the api\napi\n\n' > "$home/data/reviews/acme/codebase.units"
  out=$(run "$home" units acme codebase)
  assert_contains "$out" 'api' "units: override keeps its listed unit"
  assert_not_contains "$out" 'src' "units: override replaces the auto set"
  assert_not_contains "$out" '<root>' "units: override drops the synthetic root unit"
  pass "auto units are top-level dirs plus <root>, and an override replaces them"
}

# (b) ------------------------------------------------------------------------
test_never_reviewed_selects_units() {
  local home out
  home=$(make_home never)
  out=$(run "$home" select acme codebase)
  assert_contains "$out" 'SELECTED' "never: emits a selection"
  assert_contains "$out" 'never reviewed' "never: reasons the units as never reviewed"
  assert_contains "$out" 'src' "never: includes src"
  pass "a never-reviewed project selects its units"
}

# (c) + (d) ------------------------------------------------------------------
test_clean_is_skipped_and_changed_jumps_ahead() {
  local home head out
  home=$(make_home lifecycle)
  head=$(head_of "$home")
  FM_LEDGER_DATE=2026-07-19 run "$home" record acme codebase src --sha "$head" --verdict clean >/dev/null
  FM_LEDGER_DATE=2026-07-19 run "$home" record acme codebase api --sha "$head" --verdict clean >/dev/null

  # Both recorded-clean units are unchanged, so select must skip them.
  out=$(run "$home" select acme codebase)
  assert_not_contains "$out" ' src	' "clean: recorded-clean src is skipped"
  assert_not_contains "$out" ' api	' "clean: recorded-clean api is skipped"
  assert_contains "$out" 'docs' "clean: still offers a never-reviewed unit"

  # Touch src; it must now be a tier-1 "changed" unit, ordered before the
  # never-reviewed units, so recent work is reviewed first.
  printf 'x\n' >> "$home/projects/acme/src/a.js"
  gitc "$home/projects/acme" commit -qam "touch src"
  out=$(run "$home" select acme codebase)
  assert_contains "$out" 'changed since review' "changed: src is now changed"
  # The first listed unit line is src.
  printf '%s\n' "$out" | awk '/^  / { print; exit }' | grep -q '^  src' \
    || fail "changed: a changed unit must sort ahead of never-reviewed units"
  pass "a recorded-clean unit is skipped; a changed unit jumps ahead of never-reviewed"
}

# (e) ------------------------------------------------------------------------
test_budget_bounds_to_subset_but_at_least_one() {
  local home out count
  home=$(make_home budget)
  # A cap of 1 token is below any unit's size, so exactly one unit is selected.
  out=$(FM_LEDGER_TOKEN_CAP=1 run "$home" select acme codebase)
  count=$(printf '%s\n' "$out" | grep -c '^  ')
  [ "$count" -eq 1 ] || fail "budget: a sub-unit cap must still select exactly one unit, got $count"
  pass "the token budget bounds a run to a subset but always selects at least one unit"
}

# (f) ------------------------------------------------------------------------
test_paths_expands_root_unit() {
  local home head out
  home=$(make_home paths)
  # Record every dir clean so the only remaining candidate is <root>, whose
  # --paths output must be the actual top-level file, not the literal "<root>".
  head=$(head_of "$home")
  for u in src api docs; do
    FM_LEDGER_DATE=2026-07-19 run "$home" record acme codebase "$u" --sha "$head" --verdict clean >/dev/null
  done
  out=$(run "$home" select acme codebase --paths)
  assert_contains "$out" 'README.md' "paths: <root> expands to its top-level file"
  assert_not_contains "$out" '<root>' "paths: never leaks the synthetic unit name"
  pass "--paths expands the <root> unit to its real files"
}

# (g) ------------------------------------------------------------------------
test_history_rewrite_falls_back_to_date() {
  local home head out
  home=$(make_home rewrite)
  head=$(head_of "$home")
  FM_LEDGER_DATE=2026-07-01 run "$home" record acme codebase docs --sha "$head" --verdict clean >/dev/null
  # Orphan the recorded sha with an amend, then touch docs after it.
  gitc "$home/projects/acme" commit -q --amend -m rewritten --allow-empty
  printf 'more\n' >> "$home/projects/acme/docs/g.md"
  gitc "$home/projects/acme" commit -qam "touch docs after rewrite"
  out=$(run "$home" status acme codebase)
  printf '%s\n' "$out" | grep -E '^  docs +changed' >/dev/null \
    || fail "rewrite: an unreachable recorded sha must fall back to the date and detect the change"
  pass "an unreachable recorded sha falls back to the stored date instead of breaking"
}

# (h) ------------------------------------------------------------------------
test_nothing_to_review_when_all_clean() {
  local home head out
  home=$(make_home allclean)
  head=$(head_of "$home")
  for u in src api docs '<root>'; do
    FM_LEDGER_DATE=2026-07-19 run "$home" record acme codebase "$u" --sha "$head" --verdict clean >/dev/null
  done
  out=$(run "$home" select acme codebase)
  assert_contains "$out" 'NOTHING_TO_REVIEW' "all-clean: reports nothing to review"
  pass "select reports NOTHING_TO_REVIEW when every unit is covered and unchanged"
}

# (i) ------------------------------------------------------------------------
test_status_coverage_and_orphan() {
  local home head out
  home=$(make_home status)
  head=$(head_of "$home")
  FM_LEDGER_DATE=2026-07-19 run "$home" record acme codebase src --sha "$head" --verdict clean >/dev/null
  # A ledger row for a unit that is not in the current set must show as ORPHAN.
  FM_LEDGER_DATE=2026-07-19 run "$home" record acme codebase gone --sha "$head" --verdict clean >/dev/null
  out=$(run "$home" status acme codebase)
  assert_contains "$out" 'coverage:' "status: prints a coverage summary"
  assert_contains "$out" 'ORPHAN' "status: flags a ledger row whose unit is gone"
  pass "status reports coverage and flags orphaned ledger rows"
}

# (j) ------------------------------------------------------------------------
test_record_replaces_prior_row() {
  local home head rows
  home=$(make_home replace)
  head=$(head_of "$home")
  FM_LEDGER_DATE=2026-07-19 run "$home" record acme codebase src --sha "$head" --verdict clean >/dev/null
  FM_LEDGER_DATE=2026-07-20 run "$home" record acme codebase src --sha "$head" --verdict "https://x/pr/1" >/dev/null
  rows=$(grep -c '^| src ' "$home/data/reviews/acme/codebase.md")
  [ "$rows" -eq 1 ] || fail "record: re-recording a unit must replace its row, found $rows"
  assert_grep 'https://x/pr/1' "$home/data/reviews/acme/codebase.md" "record: keeps the latest verdict"
  pass "record replaces a unit's prior row rather than duplicating it"
}

test_auto_units_and_override
test_never_reviewed_selects_units
test_clean_is_skipped_and_changed_jumps_ahead
test_budget_bounds_to_subset_but_at_least_one
test_paths_expands_root_unit
test_history_rewrite_falls_back_to_date
test_nothing_to_review_when_all_clean
test_status_coverage_and_orphan
test_record_replaces_prior_row
