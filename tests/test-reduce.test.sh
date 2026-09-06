#!/usr/bin/env bash
# Tests for bin/test-reduce.sh: the file-level review ledger that drives a
# test-reduction campaign one bounded, disjoint pack at a time.
#
# The load-bearing behaviors:
#   (a) init seeds one pending row per test file (the three globs, node_modules
#       excluded) and is idempotent - a re-run adds only newly-created files and
#       disturbs no existing row
#   (b) next-pack bounds a pack to --size and marks the chosen files in-review
#   (c) consecutive packs are disjoint - a file picked once is never picked again
#   (d) record moves an in-review file to done, replacing its row not duplicating it
#   (e) a done file edited after its pass re-opens and is offered again (re-open)
#   (f) next-pack prints NOTHING_TO_REVIEW and exits 0 when the corpus is drained
#   (g) status reports coverage, removed/merged sums, and flags a gone file (ORPHAN)
#   (h) an unreachable recorded sha (history rewrite) falls back to the date
#   (i) prioritisation: default `count` fronts the biggest directory; `path` orders
#       lexically, so the two disagree and each is asserted
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER_SH="$ROOT/bin/test-reduce.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-reduce-tests)

gitc() { git -C "$1" -c user.name=t -c user.email=t@e.x "${@:2}"; }

# make_home <name> builds a home with a project clone "acme" whose test files sit
# in two directories of different sizes (so the count-ordering has something to
# order) plus a non-test file and a node_modules test that must be excluded.
make_home() {
  local name=$1 home repo
  home="$TMP_ROOT/$name"
  repo="$home/projects/acme"
  mkdir -p "$repo/src/big" "$repo/src/small" "$repo/node_modules/dep" "$home/data"
  printf 'a\n' > "$repo/src/big/a.test.ts"
  printf 'b\n' > "$repo/src/big/b.test.ts"
  printf 'c\n' > "$repo/src/big/c.spec.ts"
  printf 'd\n' > "$repo/src/small/d.test.tsx"
  printf 'n\n' > "$repo/node_modules/dep/e.test.ts"
  printf 'x\n' > "$repo/src/big/plain.ts"
  git -C "$repo" init -q
  gitc "$repo" add -A
  gitc "$repo" commit -qm init
  printf '%s\n' "$home"
}

run() {
  local home=$1; shift
  FM_HOME="$home" "$LEDGER_SH" "$@"
}

head_of() { git -C "$1/projects/acme" rev-parse HEAD; }
ledger_of() { printf '%s\n' "$1/data/reviews/acme/test-reduce.md"; }

# (a) ------------------------------------------------------------------------
test_init_seeds_and_is_idempotent() {
  local home out ledger
  home=$(make_home init)
  ledger=$(ledger_of "$home")
  out=$(run "$home" init acme)
  assert_contains "$out" '4 new row(s)' "init: seeds the four real test files"

  assert_grep 'src/big/a.test.ts' "$ledger" "init: tracks a .test.ts"
  assert_grep 'src/big/c.spec.ts' "$ledger" "init: tracks a .spec.ts"
  assert_grep 'src/small/d.test.tsx' "$ledger" "init: tracks a .test.tsx"
  assert_no_grep 'node_modules' "$ledger" "init: excludes node_modules"
  assert_no_grep 'plain.ts' "$ledger" "init: ignores non-test files"

  # A newly-created test file is added; existing rows are untouched. Mark one row
  # done first, then re-init, and prove that row still reads done.
  local head; head=$(head_of "$home")
  run "$home" record acme src/big/a.test.ts --outcome "clean" --sha "$head" >/dev/null
  printf 'f\n' > "$home/projects/acme/src/small/f.test.ts"
  gitc "$home/projects/acme" add -A
  gitc "$home/projects/acme" commit -qm "new test"
  out=$(run "$home" init acme)
  assert_contains "$out" '1 new row(s)' "init: idempotent re-run adds only the new file"
  assert_grep 'src/small/f.test.ts' "$ledger" "init: picks up the new file"
  grep -E '^\| src/big/a.test.ts \| done ' "$ledger" >/dev/null \
    || fail "init: a re-run must not disturb an existing row's status"
  pass "init seeds one pending row per test file and re-runs idempotently"
}

# (b) + (c) ------------------------------------------------------------------
test_next_pack_bounds_and_is_disjoint() {
  local home p1 p2 overlap
  home=$(make_home pack)
  run "$home" init acme >/dev/null
  p1=$(run "$home" next-pack acme --size 2)
  [ "$(printf '%s\n' "$p1" | grep -c .)" -eq 2 ] \
    || fail "next-pack: --size 2 must return exactly two files, got: $p1"

  # The picked files are now in-review, so the next pack cannot repeat them.
  p2=$(run "$home" next-pack acme --size 2)
  overlap=$(comm -12 <(printf '%s\n' "$p1" | sort) <(printf '%s\n' "$p2" | sort))
  [ -z "$overlap" ] || fail "next-pack: consecutive packs must be disjoint, shared: $overlap"

  local ledger; ledger=$(ledger_of "$home")
  [ "$(grep -c ' in-review ' "$ledger")" -eq 4 ] \
    || fail "next-pack: every picked file must be marked in-review"
  pass "next-pack bounds a pack to --size and packs are disjoint by construction"
}

# (d) ------------------------------------------------------------------------
test_record_transitions_in_review_to_done() {
  local home file ledger rows
  home=$(make_home record)
  run "$home" init acme >/dev/null
  file=$(run "$home" next-pack acme --size 1)
  ledger=$(ledger_of "$home")
  grep -E "^\| $file \| in-review " "$ledger" >/dev/null \
    || fail "record: precondition - the packed file should be in-review"

  run "$home" record acme "$file" --outcome "merged 2 dupes" --removed 3 --merged 2 >/dev/null
  grep -E "^\| $file \| done " "$ledger" >/dev/null \
    || fail "record: an in-review file must move to done"
  rows=$(grep -cE "^\| $file \|" "$ledger")
  [ "$rows" -eq 1 ] || fail "record: must replace the row, not duplicate it (found $rows)"
  assert_grep 'merged 2 dupes' "$ledger" "record: keeps the outcome text"
  pass "record moves an in-review file to done and replaces its row"
}

# (e) ------------------------------------------------------------------------
test_done_file_reopens_on_edit() {
  local home file head out
  home=$(make_home reopen)
  run "$home" init acme >/dev/null
  file=$(run "$home" next-pack acme --size 1)
  head=$(head_of "$home")
  run "$home" record acme "$file" --outcome clean --sha "$head" >/dev/null

  # Unchanged: the done file is not offered again.
  out=$(run "$home" next-pack acme --size 10)
  assert_not_contains "$out" "$file" "reopen: an unchanged done file is not re-offered"

  # Edit it after its pass; it must re-open and appear again.
  printf 'edit\n' >> "$home/projects/acme/$file"
  gitc "$home/projects/acme" commit -qam "edit reviewed test"
  out=$(run "$home" next-pack acme --size 10)
  assert_contains "$out" "$file" "reopen: a done file edited after its pass is offered again"
  pass "a done file edited after its pass re-opens for review"
}

# (f) ------------------------------------------------------------------------
test_nothing_to_review_when_drained() {
  local home f out head
  home=$(make_home drain)
  run "$home" init acme >/dev/null
  head=$(head_of "$home")
  # Drain every file: pack it, then record it done at HEAD (so nothing re-opens).
  while :; do
    out=$(run "$home" next-pack acme --size 10)
    [ "$out" = "NOTHING_TO_REVIEW" ] && break
    while IFS= read -r f; do
      [ -n "$f" ] && run "$home" record acme "$f" --outcome clean --sha "$head" >/dev/null
    done <<< "$out"
  done
  if ! out=$(run "$home" next-pack acme --size 10); then
    fail "drain: NOTHING_TO_REVIEW must exit 0"
  fi
  [ "$out" = "NOTHING_TO_REVIEW" ] || fail "drain: a drained corpus must print NOTHING_TO_REVIEW, got: $out"
  pass "next-pack reports NOTHING_TO_REVIEW and exits 0 when the corpus is drained"
}

# (g) ------------------------------------------------------------------------
test_status_coverage_and_orphan() {
  local home head out
  home=$(make_home status)
  run "$home" init acme >/dev/null
  head=$(head_of "$home")
  run "$home" record acme src/big/a.test.ts --outcome clean --removed 5 --merged 1 --sha "$head" >/dev/null
  # A ledger row whose file no longer exists must show ORPHAN.
  run "$home" record acme src/gone.test.ts --outcome clean --removed 2 --merged 0 --sha "$head" >/dev/null
  out=$(run "$home" status acme)
  assert_contains "$out" '1/4 test files done' "status: counts done over current total"
  assert_contains "$out" '7 tests removed' "status: sums tests removed across rows"
  assert_contains "$out" '1 duplicates merged' "status: sums duplicates merged"
  assert_contains "$out" 'ORPHAN' "status: flags a ledger row whose file is gone"
  assert_contains "$out" 'src/gone.test.ts' "status: names the orphaned file"
  pass "status reports coverage, removed/merged sums, and flags orphaned rows"
}

# (h) ------------------------------------------------------------------------
# Isolate the fallback on a NON-root commit so it is the post-date edit, not a
# root commit's list-everything diff, that re-opens the file.
test_history_rewrite_falls_back_to_date() {
  local home file repo edited_sha out
  home=$(make_home rewrite)
  repo="$home/projects/acme"
  run "$home" init acme >/dev/null
  file="src/big/a.test.ts"
  # Commit an edit to the file (a non-root commit), record it there at an old date.
  printf 'edit\n' >> "$repo/$file"
  gitc "$repo" commit -qam "edit the file"
  edited_sha=$(git -C "$repo" rev-parse HEAD)
  FM_LEDGER_DATE=2026-07-01 run "$home" record acme "$file" --outcome clean --sha "$edited_sha" >/dev/null
  # Amend the tip to orphan the recorded sha; its tree still holds the edit, so the
  # rewritten commit's diff against its parent shows the file, dated after 2026-07-01.
  gitc "$repo" commit -q --amend -m rewritten
  git -C "$repo" merge-base --is-ancestor "$edited_sha" HEAD 2>/dev/null \
    && fail "rewrite: precondition - the recorded sha must be unreachable after the amend"
  out=$(run "$home" next-pack acme --size 10)
  assert_contains "$out" "$file" "rewrite: an unreachable sha falls back to the date and re-opens the changed file"
  pass "an unreachable recorded sha falls back to the stored date instead of breaking"
}

# (i) ------------------------------------------------------------------------
test_prioritisation_count_vs_path() {
  local home repo p_count p_path
  home="$TMP_ROOT/order"
  repo="$home/projects/acme"
  # A lexically-first dir "aaa" with ONE test, and a lexically-last dir "zzz" with
  # THREE - so count-order (biggest cluster first) and path-order disagree.
  mkdir -p "$repo/aaa" "$repo/zzz" "$home/data"
  printf 't\n' > "$repo/aaa/one.test.ts"
  printf 't\n' > "$repo/zzz/x.test.ts"
  printf 't\n' > "$repo/zzz/y.test.ts"
  printf 't\n' > "$repo/zzz/z.test.ts"
  git -C "$repo" init -q
  gitc "$repo" add -A
  gitc "$repo" commit -qm init
  run "$home" init acme >/dev/null

  p_count=$(FM_TEST_REDUCE_ORDER=count run "$home" next-pack acme --size 1)
  case "$p_count" in zzz/*) : ;; *) fail "order: count must front the biggest dir, got '$p_count'" ;; esac

  # Reset the in-review mark by re-seeding a fresh ledger, then check path order.
  rm -f "$home/data/reviews/acme/test-reduce.md"
  run "$home" init acme >/dev/null
  p_path=$(FM_TEST_REDUCE_ORDER=path run "$home" next-pack acme --size 1)
  case "$p_path" in aaa/*) : ;; *) fail "order: path must front the lexically-first file, got '$p_path'" ;; esac
  pass "prioritisation defaults to count (biggest cluster first); path orders lexically"
}

test_init_seeds_and_is_idempotent
test_next_pack_bounds_and_is_disjoint
test_record_transitions_in_review_to_done
test_done_file_reopens_on_edit
test_nothing_to_review_when_drained
test_status_coverage_and_orphan
test_history_rewrite_falls_back_to_date
test_prioritisation_count_vs_path
