#!/usr/bin/env bash
# tests/fm-wt-activity.test.sh - watch the work, not just the screen.
#
# The watcher used to see only the pane, which lies in both directions:
#   - a crew committing steadily but quiet for five minutes has a STATIC pane and
#     was indistinguishable from a wedged one, so it surfaced and cost a peek;
#   - a crew spinning without touching a file has a LIVELY pane, so no stale wake
#     ever fired and only the slow heartbeat could ever notice.
# bin/fm-wt-activity-lib.sh reads the worktree, which fakes neither. This suite
# covers the probe itself, the absorb it now makes free, and the wedge it now makes
# visible - including the narrow gates that keep a scout and a long build quiet.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-wt-activity-lib.sh
. "$ROOT/bin/fm-wt-activity-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-wt-activity-tests)

make_repo() {  # <dir>
  local wt=$1
  mkdir -p "$wt"
  git -C "$wt" init -q 2>/dev/null
  git -C "$wt" config user.email crew@example.invalid
  git -C "$wt" config user.name crew
  printf 'one\n' > "$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" commit -qm first
}

# A pane that CHANGES on every capture: the crew looks alive on screen, which is
# precisely the state in which no stale wake can ever fire.
make_live_pane_tmux() {  # <fakebin> <window>
  local fakebin=$1 window=$2
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = "list-windows" ]; then printf '%s\n' "$window"; exit 0; fi
if [ "\${1:-}" = "capture-pane" ]; then
  cat "\${FM_FAKE_TMUX_CAPTURE:-/dev/null}" 2>/dev/null
  printf 'thinking %s\n' "\$(date +%s%N)"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/tmux"
}

# --- the probe --------------------------------------------------------------

test_snapshot_and_progress_rule() {
  local dir wt s1 s2 s3
  dir=$(make_case wt-probe); wt="$dir/wt"
  make_repo "$wt"

  s1=$(wt_activity_snapshot "$wt")
  assert_contains "$s1" "head=$(git -C "$wt" rev-parse --short HEAD)" "snapshot lost HEAD"
  assert_contains "$s1" "dirty=0" "clean worktree not reported clean"
  # idx= is the index mtime, and it is read from a path git reports RELATIVE to the
  # worktree: an un-rooted stat silently yields 0 forever and kills the stage leg.
  assert_not_contains "$s1" "idx=0" "the index mtime was not read (idx=0 means the stat missed the file)"

  # Staging alone - no commit, no edit - is progress.
  printf 'staged\n' > "$wt/s.txt"
  git -C "$wt" add s.txt
  wt_activity_advanced "$s1" "$(wt_activity_snapshot "$wt")" \
    || fail "staging a file was not read as progress (the index leg is dead)"

  # Absence of evidence is never progress.
  wt_activity_advanced "$s1" "$s1" && fail "an identical snapshot was read as progress"
  wt_activity_advanced "" "$s1" && fail "a missing baseline was read as progress"
  wt_activity_advanced "$s1" "" && fail "a missing snapshot was read as progress"

  printf 'two\n' > "$wt/b.txt"
  git -C "$wt" add b.txt
  git -C "$wt" commit -qm second
  s2=$(wt_activity_snapshot "$wt")
  wt_activity_advanced "$s1" "$s2" || fail "a new commit was not read as progress"

  sleep 1
  printf 'edit\n' >> "$wt/a.txt"
  s3=$(wt_activity_snapshot "$wt")
  wt_activity_advanced "$s2" "$s3" || fail "an uncommitted edit was not read as progress"
  assert_contains "$s3" "dirty=1" "the edited file was not counted"

  # A worktree that is not a repo (or is gone) yields no snapshot at all, which the
  # callers must treat as "no evidence", never as "no progress".
  [ -z "$(wt_activity_snapshot "$dir/not-a-repo")" ] || fail "a non-repo produced a snapshot"
  [ -z "$(FM_WT_PROBE=0 wt_activity_snapshot "$wt")" ] || fail "FM_WT_PROBE=0 did not disable the probe"
  pass "the probe reads commits, stages and edits, and never invents evidence"
}

# --- a committing crew on a static pane is absorbed, for free ---------------

test_stale_pane_absorbed_when_worktree_advanced() {
  local dir wt state fakebin out probes capture window pid
  dir=$(make_case wt-absorb); state="$dir/state"; fakebin="$dir/fakebin"
  wt="$dir/wt"; out="$dir/watch.out"; probes="$dir/probes"; capture="$dir/capture"
  window="sess:fm-wa1"
  make_repo "$wt"
  : > "$probes"
  printf 'compiling\n' > "$capture"
  fm_write_meta "$state/wa1.meta" "window=$window" "worktree=$wt" "kind=ship"
  printf 'working: mid-task\n' > "$state/wa1.status"
  # Primed, so the pre-existing status does not fire the signal path: this case is
  # about the STALE path (the signal path's own worktree absorb is the next case).
  printf '%s' "$(stat -c '%s:%Y' "$state/wa1.status" 2>/dev/null || stat -f '%z:%Fm' "$state/wa1.status")" \
    > "$state/.seen-wa1_status"

  # Baseline snapshot: the watcher has seen this worktree before.
  printf '%s\n' "$(wt_activity_snapshot "$wt")" > "$state/.wt-snap-wa1"
  printf '%s\n' "$(date +%s)" > "$state/.wt-since-wa1"
  # ... and then the crew commits, while its pane sits perfectly still.
  printf 'landed\n' > "$wt/c.txt"
  git -C "$wt" add c.txt
  git -C "$wt" commit -qm landed

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · stopped' FM_FAKE_CREW_STATE_LOG="$probes" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  sleep 5
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  grep -q 'stale:' "$out" && fail "a crew that had just committed was surfaced as stale: $(cat "$out")"
  [ ! -s "$probes" ] || fail "the absorb paid for a pane probe the worktree had already answered"
  assert_grep "worktree advanced" "$state/.watch-triage.log" "the absorb was not attributed to the worktree"
  pass "a static pane whose worktree just advanced is absorbed with no probe"
}

# --- a working: note from a crew that is committing is absorbed too ----------

test_signal_absorbed_when_worktree_advanced() {
  local dir wt state fakebin out probes capture window pid
  dir=$(make_case wt-signal); state="$dir/state"; fakebin="$dir/fakebin"
  wt="$dir/wt"; out="$dir/watch.out"; probes="$dir/probes"; capture="$dir/capture"
  window="sess:fm-wn1"
  make_repo "$wt"
  : > "$probes"
  printf 'compiling\n' > "$capture"
  fm_write_meta "$state/wn1.meta" "window=$window" "worktree=$wt" "kind=ship"
  printf '%s\n' "$(wt_activity_snapshot "$wt")" > "$state/.wt-snap-wn1"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · stopped' FM_FAKE_CREW_STATE_LOG="$probes" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  sleep 0.5
  printf 'landed\n' > "$wt/c.txt"
  git -C "$wt" add c.txt
  git -C "$wt" commit -qm landed
  printf 'working: rebased and pressing on\n' > "$state/wn1.status"
  sleep 4
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  grep -q 'signal:' "$out" && fail "a working: note from a crew that had just committed woke firstmate: $(cat "$out")"
  [ ! -s "$probes" ] || fail "the signal absorb paid for a pane probe the worktree had already answered"
  pass "a no-verb signal from a crew whose worktree advanced is absorbed with no probe"
}

# --- a spinning crew on a live pane is surfaced ------------------------------

spin_watch() {  # <state> <fakebin> <out> <window> <capture> [extra env...]
  local state=$1 fakebin=$2 out=$3 window=$4 capture=$5
  shift 5
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_WT_FRESH_SECS=0 FM_WT_STILL_SECS=2 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$WATCH" > "$out" &
}

test_spinning_crew_surfaces() {
  local dir wt state fakebin out capture window pid
  dir=$(make_case wt-spin); state="$dir/state"; fakebin="$dir/fakebin"
  wt="$dir/wt"; out="$dir/watch.out"; capture="$dir/capture"
  window="sess:fm-ws1"
  make_repo "$wt"
  : > "$capture"
  make_live_pane_tmux "$fakebin" "$window"
  fm_write_meta "$state/ws1.meta" "window=$window" "worktree=$wt" "kind=ship"
  printf 'working: looking into it\n' > "$state/ws1.status"
  printf '%s' "$(stat -c '%s:%Y' "$state/ws1.status" 2>/dev/null || stat -f '%z:%Fm' "$state/ws1.status")" \
    > "$state/.seen-ws1_status"

  spin_watch "$state" "$fakebin" "$out" "$window" "$capture"
  pid=$!
  wait_for_exit "$pid" 120 || fail "a spinning crew never surfaced: $(cat "$out")"

  assert_grep "stale: $window | task=ws1 class=spinning wt=still" "$out" \
    "the spinning wake did not carry its verdict and evidence"
  pass "a lively pane whose worktree has not moved surfaces as spinning"
}

test_spinning_gates() {
  local dir wt state fakebin out capture window pid
  dir=$(make_case wt-spin-gates); state="$dir/state"; fakebin="$dir/fakebin"
  wt="$dir/wt"; out="$dir/watch.out"; capture="$dir/capture"
  window="sess:fm-wg1"
  make_repo "$wt"
  make_live_pane_tmux "$fakebin" "$window"

  # A scout writes its report OUTSIDE the worktree, so a motionless worktree is it
  # doing its job, not spinning.
  : > "$capture"
  fm_write_meta "$state/wg1.meta" "window=$window" "worktree=$wt" "kind=scout"
  printf 'working: reading the code\n' > "$state/wg1.status"
  printf '%s' "$(stat -c '%s:%Y' "$state/wg1.status" 2>/dev/null || stat -f '%z:%Fm' "$state/wg1.status")" \
    > "$state/.seen-wg1_status"
  spin_watch "$state" "$fakebin" "$out" "$window" "$capture"
  pid=$!
  sleep 6
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -q 'class=spinning' "$out" && fail "a scout with a motionless worktree was called spinning"

  # A long build or test run is legitimately motionless, and its harness says so on
  # the pane. Same worktree, ship task, but a busy signature.
  rm -f "$state"/.wt-* "$state"/.hash-* "$out"
  fm_write_meta "$state/wg1.meta" "window=$window" "worktree=$wt" "kind=ship"
  printf 'esc to interrupt\n' > "$capture"
  spin_watch "$state" "$fakebin" "$out" "$window" "$capture"
  pid=$!
  sleep 6
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -q 'class=spinning' "$out" && fail "a busy pane (a running build) was called spinning"
  pass "spinning stays narrow: not a scout, not a busy pane"
}

test_snapshot_and_progress_rule
test_stale_pane_absorbed_when_worktree_advanced
test_signal_absorbed_when_worktree_advanced
test_spinning_crew_surfaces
test_spinning_gates
