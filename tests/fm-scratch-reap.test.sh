#!/usr/bin/env bash
# Tests for bin/fm-scratch-reap.sh: the janitor that reclaims orphaned harness
# scratchpad session dirs.
#
# Load-bearing behaviors:
#   (a) a session dir untouched past the threshold is reaped; a fresh one is spared
#   (b) --protect and --self spare a dir regardless of age
#   (c) --dry-run deletes nothing
#   (d) the root must be a claude-<uid> scratch root, or the reaper refuses
#   (e) non-session siblings (bundled-skills/<version>) are never touched
#   (f) an emptied project-encoded parent dir is cleaned up
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAP="$ROOT/bin/fm-scratch-reap.sh"
TMP_ROOT=$(fm_test_tmproot fm-scratch-reap-tests)

# Build a fake harness scratch root with a dead session, a fresh session, and a
# non-session sibling. Echoes the root path.
make_scratch() {
  local name=$1 root
  root="$TMP_ROOT/$name/claude-1001"
  mkdir -p "$root/-proj-a/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/scratchpad" \
           "$root/-proj-b/11111111-2222-3333-4444-555555555555/scratchpad" \
           "$root/bundled-skills/2.1.210"
  echo dead > "$root/-proj-a/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/scratchpad/f"
  touch -d '3 days ago' "$root/-proj-a/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/scratchpad/f"
  echo live > "$root/-proj-b/11111111-2222-3333-4444-555555555555/scratchpad/f"
  echo skill > "$root/bundled-skills/2.1.210/y"
  printf '%s\n' "$root"
}

DEAD=-proj-a/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
LIVE=-proj-b/11111111-2222-3333-4444-555555555555

test_reaps_dead_spares_fresh() {
  local root
  root=$(make_scratch reap)
  FM_SCRATCH_ROOT="$root" "$REAP" >/dev/null 2>&1 || fail "reaper exited non-zero"
  [ ! -e "$root/$DEAD" ] || fail "dead session (untouched 3d) was not reaped"
  [ -e "$root/$LIVE" ] || fail "fresh session was reaped (must be spared)"
  [ -e "$root/bundled-skills/2.1.210" ] || fail "non-session sibling was reaped"
  pass "reaps a session untouched past the threshold, spares a fresh one and non-session siblings"
}

test_cleans_emptied_parent() {
  local root
  root=$(make_scratch parent)
  FM_SCRATCH_ROOT="$root" "$REAP" >/dev/null 2>&1
  [ ! -e "$root/-proj-a" ] || fail "emptied project-encoded parent dir was left behind"
  [ -e "$root/-proj-b" ] || fail "a parent that still holds a live session was removed"
  pass "removes an emptied project-encoded parent, keeps a populated one"
}

test_protect_spares_regardless_of_age() {
  local root
  root=$(make_scratch protect)
  FM_SCRATCH_ROOT="$root" "$REAP" --protect aaaaaaaa >/dev/null 2>&1
  [ -e "$root/$DEAD" ] || fail "--protect did not spare the matching dead session"
  # --self is an alias for the same protection.
  root=$(make_scratch self)
  FM_SCRATCH_ROOT="$root" "$REAP" --self aaaaaaaa-bbbb >/dev/null 2>&1
  [ -e "$root/$DEAD" ] || fail "--self did not spare the matching session"
  pass "--protect / --self spare a dir regardless of age"
}

test_dry_run_deletes_nothing() {
  local root out
  root=$(make_scratch dry)
  out=$(FM_SCRATCH_ROOT="$root" "$REAP" --dry-run 2>&1)
  [ -e "$root/$DEAD" ] || fail "--dry-run deleted a session dir"
  assert_contains "$out" 'would reap' "--dry-run: reports the candidate"
  pass "--dry-run reports candidates and deletes nothing"
}

test_refuses_non_harness_root() {
  local dir rc=0
  dir="$TMP_ROOT/notclaude/random-dir"
  mkdir -p "$dir"
  FM_SCRATCH_ROOT="$dir" "$REAP" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "reaper did not refuse a root that is not claude-<uid> (rc=$rc)"
  [ -e "$dir" ] || fail "reaper touched a refused root"
  pass "refuses a root whose basename is not claude-<uid>"
}

test_max_age_threshold_respected() {
  local root
  root=$(make_scratch age)
  # A 96h threshold spares the 3-day-old (72h) dead session.
  FM_SCRATCH_ROOT="$root" "$REAP" --max-age-hours 96 >/dev/null 2>&1
  [ -e "$root/$DEAD" ] || fail "session younger than the threshold was reaped"
  # A 1h threshold reaps it.
  FM_SCRATCH_ROOT="$root" "$REAP" --max-age-hours 1 >/dev/null 2>&1
  [ ! -e "$root/$DEAD" ] || fail "session older than a 1h threshold was not reaped"
  pass "--max-age-hours gates reaping by the untouched window"
}

test_reaps_dead_spares_fresh
test_cleans_emptied_parent
test_protect_spares_regardless_of_age
test_dry_run_deletes_nothing
test_refuses_non_harness_root
test_max_age_threshold_respected
