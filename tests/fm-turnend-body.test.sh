#!/usr/bin/env bash
# tests/fm-turnend-body.test.sh - the turn-end marker's body.
#
# state/<id>.turn-ended used to be a payload-free `touch`, so it said only THAT a
# turn ended. Every no-verb turn end therefore cost a pane probe, and a crew that
# had merely finished a subtask and gone briefly idle cost firstmate a full peek.
#
# The marker now carries one line of body (bin/fm-turnend-mark.sh owns the format:
# a turn counter plus bin/fm-wt-activity-lib.sh's worktree snapshot), and the
# watcher absorbs a turn end whose body proves the crew moved the work - with NO
# probe. The absorb stays conservative: no body, no previous body, or an unchanged
# worktree all fall back to the probe, so nothing that used to surface stops
# surfacing.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
MARK="$ROOT/bin/fm-turnend-mark.sh"
TMP_ROOT=$(fm_test_tmproot fm-turnend-body-tests)

seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# A real worktree, because the whole point of the probe is that it reads git.
make_repo() {  # <dir>
  local wt=$1
  mkdir -p "$wt"
  git -C "$wt" init -q 2>/dev/null
  git -C "$wt" config user.email crew@example.invalid
  git -C "$wt" config user.name crew
  printf 'one\n' > "$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" commit -qm first
  printf '%s' "$wt"
}

# --- the writer -------------------------------------------------------------

test_marker_carries_a_body() {
  local dir wt state marker body head2
  dir=$(make_case turnend-writer); state="$dir/state"; wt="$dir/wt"
  make_repo "$wt" >/dev/null
  marker="$state/tw1.turn-ended"

  "$MARK" "$marker" "$wt"
  body=$(cat "$marker")
  [ "$(wc -l < "$marker" | tr -d ' ')" = 1 ] || fail "marker is not a one-line body: $body"
  assert_contains "$body" "turn=1" "first turn end did not start the turn counter"
  assert_contains "$body" "head=$(git -C "$wt" rev-parse --short HEAD)" "body did not carry the worktree HEAD"
  assert_contains "$body" "dirty=0" "clean worktree not reported clean"

  # A second turn end that committed: the counter advances and HEAD moves, which is
  # exactly the evidence the watcher reads.
  printf 'two\n' > "$wt/b.txt"
  git -C "$wt" add b.txt
  git -C "$wt" commit -qm second
  "$MARK" "$marker" "$wt"
  body=$(cat "$marker")
  head2=$(git -C "$wt" rev-parse --short HEAD)
  assert_contains "$body" "turn=2" "turn counter did not increment across turn ends"
  assert_contains "$body" "head=$head2" "body did not follow HEAD to the new commit"

  # No worktree, and an unwritable marker, must never fail a harness's turn.
  "$MARK" "$state/tw-noworktree.turn-ended" || fail "writer failed with no worktree argument"
  assert_contains "$(cat "$state/tw-noworktree.turn-ended")" "turn=1" "worktree-less marker lost its turn counter"
  "$MARK" || fail "writer failed with no arguments at all"
  pass "the turn-end marker carries turn count and worktree evidence, and never fails a turn"
}

# --- the classifier ---------------------------------------------------------

test_progress_and_no_progress() {
  local dir wt state
  dir=$(make_case turnend-classify); state="$dir/state"; wt="$dir/wt"
  make_repo "$wt" >/dev/null

  "$MARK" "$state/tc1.turn-ended" "$wt"
  turnend_shows_progress "$state" tc1 && fail "a first turn end with no baseline claimed progress"
  turnend_record_seen "$state" "$state/tc1.turn-ended"
  turnend_shows_progress "$state" tc1 && fail "an unchanged worktree claimed progress"

  printf 'more\n' > "$wt/c.txt"
  git -C "$wt" add c.txt
  git -C "$wt" commit -qm third
  "$MARK" "$state/tc1.turn-ended" "$wt"
  turnend_shows_progress "$state" tc1 || fail "a turn end that committed did not show progress"

  # An edit that is not yet committed is progress too.
  turnend_record_seen "$state" "$state/tc1.turn-ended"
  sleep 1
  printf 'edited\n' >> "$wt/a.txt"
  "$MARK" "$state/tc1.turn-ended" "$wt"
  turnend_shows_progress "$state" tc1 || fail "a turn end that edited a tracked file did not show progress"
  pass "progress is committed/staged/edited work, and never the absence of evidence"
}

# --- the watcher: absorbed for free ----------------------------------------

test_watcher_absorbs_progress_without_a_probe() {
  local dir wt state fakebin out probes pid
  dir=$(make_case turnend-absorb); state="$dir/state"; fakebin="$dir/fakebin"
  wt="$dir/wt"; out="$dir/watch.out"; probes="$dir/probes"
  make_repo "$wt" >/dev/null
  : > "$probes"
  # No meta, so no window: this isolates the SIGNAL path. The stale path enumerates
  # windows and is the subject of its own suite (tests/fm-wt-activity.test.sh); a
  # window here would let its probe pollute this one's zero-probe assertion.

  # Baseline turn end, already seen by the watcher.
  "$MARK" "$state/ta1.turn-ended" "$wt"
  turnend_record_seen "$state" "$state/ta1.turn-ended"
  printf '%s' "$(seen_sig "$state/ta1.turn-ended")" > "$state/.seen-ta1_turn-ended"

  # The crew commits and ends another turn. Its pane would report "not working"
  # (it is between turns), which is precisely the case that used to surface.
  printf 'work\n' > "$wt/d.txt"
  git -C "$wt" add d.txt
  git -C "$wt" commit -qm work

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · stopped' FM_FAKE_CREW_STATE_LOG="$probes" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # A full second, so the marker's size:mtime signature (the watcher's change
  # detector, at 1s granularity) is unambiguously new.
  sleep 1.2
  "$MARK" "$state/ta1.turn-ended" "$wt"
  sleep 4
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  grep -q 'signal:' "$out" && fail "a turn end that committed work still woke firstmate: $(cat "$out")"
  [ ! -s "$probes" ] || fail "the absorb paid for a pane probe it should not need: $(cat "$probes")"
  assert_grep "absorbed benign" "$state/.watch-triage.log" "the progress turn-end was not recorded as absorbed"
  pass "a turn end whose body proves progress is absorbed with zero probes and zero wakes"
}

# --- the watcher: still surfaces a stopped crew ----------------------------

test_watcher_still_surfaces_a_stopped_crew() {
  local dir wt state fakebin out probes pid
  dir=$(make_case turnend-surface); state="$dir/state"; fakebin="$dir/fakebin"
  wt="$dir/wt"; out="$dir/watch.out"; probes="$dir/probes"
  make_repo "$wt" >/dev/null
  : > "$probes"
  # No meta, for the same reason as the absorb case above: signal path only.

  "$MARK" "$state/ts1.turn-ended" "$wt"
  turnend_record_seen "$state" "$state/ts1.turn-ended"
  printf '%s' "$(seen_sig "$state/ts1.turn-ended")" > "$state/.seen-ts1_turn-ended"

  # A turn ends having changed NOTHING in the worktree, and the crew is not busy:
  # no positive evidence anywhere, so this must still surface.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · stopped' FM_FAKE_CREW_STATE_LOG="$probes" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  sleep 1.2
  "$MARK" "$state/ts1.turn-ended" "$wt"
  wait_for_exit "$pid" 80 || fail "a no-progress turn end from an idle crew did not surface"

  assert_grep "signal: $state/ts1.turn-ended | task=ts1" "$out" \
    "the surfaced no-progress turn end lost its payload evidence"
  [ -s "$probes" ] || fail "the fallback did not consult the crew's endpoint at all"
  pass "a turn end with no worktree progress still falls back to the probe and surfaces"
}

test_marker_carries_a_body
test_progress_and_no_progress
test_watcher_absorbs_progress_without_a_probe
test_watcher_still_surfaces_a_stopped_crew
