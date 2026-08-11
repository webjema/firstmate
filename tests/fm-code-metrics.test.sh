#!/usr/bin/env bash
# Tests for bin/fm-code-metrics.sh: the per-project drift metrics a tending pass
# records so a codebase moving in a direction nobody chose shows up as a number
# instead of as a surprise a year later.
#
# The load-bearing behaviors:
#   (a) the comment share is COUNTED, not estimated - a file with a known split
#       produces exactly the expected percentage, including block comments and
#       continuation lines, because the whole tool is worthless if the number is
#       only roughly right
#   (b) `new_cmt%` reads only the lines ADDED since the previously recorded sha.
#       This is the leading indicator and the reason the tool exists: on optiroq
#       the whole-tree share sat at 24% while newly written code was at 44%, so a
#       tool that only reported the tree average would have said nothing was wrong
#   (c) test files are kept out of the code and comment counts and reported
#       separately - tests are legitimately verbose and would mask the signal
#   (d) a file whose extension has no known comment syntax is not counted at all,
#       rather than counted with the wrong rules
#   (e) recording NEVER fails on thresholds - there are none; it reports and exits
#       zero, so no pass can ever be blocked or tempted to disable it
#   (f) the first pass says so instead of inventing a delta against nothing
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

METRICS="$ROOT/bin/fm-code-metrics.sh"
TMP_ROOT=$(fm_test_tmproot fm-code-metrics-tests)

fm_git_identity

# A firstmate home with one project clone, laid out the way the script resolves:
# $HOME/projects/<name> for the clone, $HOME/data for the records.
make_home() {
  local name=$1 home="$TMP_ROOT/$1-home"
  mkdir -p "$home/projects" "$home/data"
  fm_git_init_commit "$home/projects/$name" >/dev/null 2>&1
  printf '%s\n' "$home"
}

run_metrics() { # <home> <args...>
  local home=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" bash "$METRICS" "$@" 2>&1
}

commit_all() { # <repo> <message>
  git -C "$1" add -A
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "$2"
}

# Read one column out of the last recorded row. Columns are 1-indexed and match
# the header the script writes.
last_col() { # <home> <project> <column-index>
  awk -F'\t' -v c="$3" 'NR > 1 { v = $c } END { print v }' "$1/data/reviews/$2/metrics.tsv"
}

# --- (a) the comment share is counted exactly --------------------------------

home=$(make_home alpha)
repo="$home/projects/alpha"

# 6 code lines, 4 comment lines (one //, one three-line block), blanks ignored.
cat > "$repo/thing.ts" <<'TS'
// a leading line comment
const a = 1;

/* a block comment
   that continues
   and ends here */
const b = 2;
const c = 3;
const d = 4;
const e = 5;
const f = 6;
TS
commit_all "$repo" "add thing.ts"

out=$(run_metrics "$home" record alpha)
expect_code 0 $? "record must exit zero"
assert_contains "$out" "recorded alpha" "record should name the project"

code=$(last_col "$home" alpha 4)
[ "$code" = "6" ] || fail "expected 6 code lines, got '$code'"
cmt=$(last_col "$home" alpha 5)
# 4 comment / 10 counted = 40.0
[ "$cmt" = "40.0" ] || fail "expected comment share 40.0, got '$cmt'"
pass "counts code and comment lines exactly, block comments included"

# --- (f) the first pass admits it has nothing to compare against -------------

assert_contains "$out" "first recorded pass" "a first pass must say there is no delta yet"
assert_not_contains "$out" "delta since" "a first pass must not invent a delta"
pass "first pass reports no delta instead of inventing one"

# --- (b) new_cmt% reads only what was added since the last recorded sha ------

# The tree so far is 40% comments. Add a file that is 80% comments and nothing
# else: the tree average barely moves, but new_cmt% must report the new code.
cat > "$repo/fresh.ts" <<'TS'
// one
// two
// three
// four
// five
// six
// seven
// eight
const x = 1;
const y = 2;
TS
commit_all "$repo" "add fresh.ts"

out=$(run_metrics "$home" record alpha)
new_cmt=$(last_col "$home" alpha 6)
# 8 comment / 10 added counted lines = 80.0
[ "$new_cmt" = "80.0" ] || fail "expected new_cmt% 80.0 for the added lines, got '$new_cmt'"
tree_cmt=$(last_col "$home" alpha 5)
# The tree is now 12 comment / 20 counted = 60.0, so the leading indicator is
# 20 points ahead of the lagging one. That gap is the whole point of the pair.
[ "$tree_cmt" = "60.0" ] || fail "expected tree comment share 60.0, got '$tree_cmt'"
assert_contains "$out" "delta since" "a second pass must print a delta"
pass "new_cmt% measures only lines added since the last recorded sha"

# --- (c) tests are counted separately, not folded into the source share ------

home=$(make_home beta)
repo="$home/projects/beta"
cat > "$repo/src.ts" <<'TS'
const a = 1;
const b = 2;
TS
mkdir -p "$repo/tests"
# Heavily commented, and in a test path: it must not move the source share.
cat > "$repo/tests/src.test.ts" <<'TS'
// test comment one
// test comment two
// test comment three
expect(1).toBe(1);
TS
commit_all "$repo" "add source and test"

run_metrics "$home" record beta >/dev/null
code=$(last_col "$home" beta 4)
cmt=$(last_col "$home" beta 5)
[ "$code" = "2" ] || fail "test lines must not count as source code, got '$code'"
[ "$cmt" = "0.0" ] || fail "test comments must not move the source share, got '$cmt'"
testpct=$(last_col "$home" beta 10)
# 1 test code line against 2 source code lines = 50.0
[ "$testpct" = "50.0" ] || fail "expected test share 50.0, got '$testpct'"
pass "test files are excluded from the source counts and reported separately"

# --- (d) an unknown extension is skipped, not guessed at ---------------------

home=$(make_home gamma)
repo="$home/projects/gamma"
cat > "$repo/only.ts" <<'TS'
const a = 1;
TS
# Lisp: `;` comments. Counting it under either known family would be wrong, so
# the file must not be counted at all.
cat > "$repo/thing.lisp" <<'LISP'
; a comment the C and hash families would both read as code
(defun f () 1)
(defun g () 2)
LISP
commit_all "$repo" "add a file with no known comment syntax"

run_metrics "$home" record gamma >/dev/null
code=$(last_col "$home" gamma 4)
[ "$code" = "1" ] || fail "unknown-extension files must not be counted, got '$code' code lines"
pass "a file with no known comment syntax is skipped, not counted wrongly"

# --- (e) no thresholds: a terrible codebase still exits zero -----------------

home=$(make_home delta)
repo="$home/projects/delta"
{
  echo "const a = 1;"
  for i in $(seq 1 50); do echo "// comment $i"; done
  for i in $(seq 1 20); do echo "const x$i = 1 as any;"; done
} > "$repo/awful.ts"
commit_all "$repo" "add a file that violates every taste"

out=$(run_metrics "$home" record delta)
rc=$?
expect_code 0 "$rc" "a bad codebase must still exit zero - this tool reports, it never gates"
escapes=$(last_col "$home" delta 7)
[ "$escapes" = "20" ] || fail "expected 20 escape hatches counted, got '$escapes'"
assert_not_contains "$out" "error" "reporting must not read as a failure"
pass "records without judging: no threshold, no non-zero exit"

# --- show and delta are read-only -------------------------------------------

before=$(cat "$home/data/reviews/delta/metrics.tsv")
run_metrics "$home" show delta >/dev/null
run_metrics "$home" delta delta >/dev/null
after=$(cat "$home/data/reviews/delta/metrics.tsv")
[ "$before" = "$after" ] || fail "show and delta must not write to the history"
pass "show and delta leave the history untouched"

# --- an unknown project fails loudly rather than recording nothing -----------

out=$(run_metrics "$home" record no-such-project) && rc=0 || rc=$?
expect_code 1 "$rc" "an unresolvable project must fail"
assert_contains "$out" "no git repo" "the failure must name what was missing"
pass "an unknown project is an error, not a silent empty record"

echo "all fm-code-metrics tests passed"
