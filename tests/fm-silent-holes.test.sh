#!/usr/bin/env bash
# tests/fm-silent-holes.test.sh - the two things the wake path could not see.
#
# (a) A WEDGED SECONDMATE was invisible. fm-watch.sh skipped stale detection for
#     kind=secondmate unless the log said paused:, and fm-crew-state.sh exempted
#     secondmates from the busy check, so a secondmate that froze mid-task produced
#     no stale wake at all, ever. The blanket skip existed for a good reason - an
#     idle secondmate is healthy BY CHARTER and must stay silent - so the fix is to
#     distinguish idle from wedged, not to start surfacing idle secondmates.
#
# (b) An OPEN DECISION could be MASKED. status_open_decisions folds the whole log
#     into the decisions still open, but the watcher's triage only read the LAST
#     line, so a still-open needs-decision followed by any later working: note was
#     invisible to the wake path. The wake path now consumes the fold - and only
#     when the open SET CHANGES, so a decision firstmate is already chewing on does
#     not re-wake it on the crew's next progress note.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-silent-holes-tests)

seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

watch_bg() {  # <state> <fakebin> <out> [extra env...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# --- (a) a wedged secondmate ------------------------------------------------

test_idle_secondmate_stays_silent() {
  local dir state fakebin out capture window pid home
  dir=$(make_case sm-idle); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/capture"; window="sess:fm-sm1"
  home="$dir/home"; mkdir -p "$home/state"
  printf 'idle, waiting for work\n' > "$capture"
  fm_write_meta "$state/sm1.meta" "window=$window" "kind=secondmate" "home=$home"

  # No status file, no crew of its own: nothing is expected of it. This is the
  # charter's healthy idle, and it must produce no wake however long it sits.
  FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · idle' \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  sleep 5
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [ ! -s "$out" ] || fail "an idle secondmate woke firstmate: $(cat "$out")"
  pass "an idle secondmate is healthy by charter and stays silent"
}

test_wedged_secondmate_surfaces() {
  local dir state fakebin out capture window pid home
  dir=$(make_case sm-wedged); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/capture"; window="sess:fm-sm2"
  home="$dir/home"; mkdir -p "$home/state"
  printf 'frozen mid-task\n' > "$capture"
  fm_write_meta "$state/sm2.meta" "window=$window" "kind=secondmate" "home=$home"

  # It has crew of its own in flight - work it MUST be alive to supervise - and its
  # pane is frozen. Its own `working:` line is deliberately not the evidence: a
  # secondmate writes one while merely standing by.
  fm_write_meta "$home/state/child-9.meta" "window=sess:fm-child-9" "kind=ship"
  printf 'working: the parent supervises this secondmate\n' > "$state/sm2.status"
  printf '%s' "$(seen_sig "$state/sm2.status")" > "$state/.seen-sm2_status"

  FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · stopped' \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 120 || fail "a wedged secondmate with live work never surfaced"

  assert_grep "stale: $window | task=sm2 class=none kind=secondmate" "$out" \
    "the wedged-secondmate wake did not carry its evidence"
  pass "a secondmate that froze with live work surfaces as stale"
}

test_secondmate_with_crew_of_its_own_counts_as_live_work() {
  local dir state home
  dir=$(make_case sm-live-work); state="$dir/state"
  home="$dir/home"; mkdir -p "$home/state"
  fm_write_meta "$state/sm3.meta" "window=sess:fm-sm3" "kind=secondmate" "home=$home"

  secondmate_has_live_work "$state" sm3 && fail "an idle secondmate was called live"

  # A standing-by secondmate writes a working: line. That is NOT live work - treating
  # it as such would surface every healthy idle secondmate.
  printf 'working: the parent supervises this secondmate\n' > "$state/sm3.status"
  secondmate_has_live_work "$state" sm3 && fail "a standing-by working: line was called live work"

  # Crew of its own in flight IS live work: it must be alive to supervise them.
  fm_write_meta "$home/state/child-1.meta" "window=sess:fm-child-1" "kind=ship"
  secondmate_has_live_work "$state" sm3 || fail "a secondmate with crew in flight was called idle"

  # Its crew torn down: idle again.
  rm -f "$home/state/child-1.meta"
  secondmate_has_live_work "$state" sm3 && fail "a secondmate whose crew is gone was called live"
  pass "live work is crew of its own in flight, never a standing-by working: line"
}

# --- (b) a masked open decision ---------------------------------------------

test_masked_open_decision_surfaces() {
  local dir state fakebin out pid status_file
  dir=$(make_case decision-masked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/dm1.status"
  fm_write_meta "$state/dm1.meta" "window=sess:fm-dm1" "kind=ship"

  # The crew asked a question and then carried on with something else. The LAST line
  # is a routine working: note, and the crew is provably working - so every test the
  # old wake path had says "absorb", and the question sits unasked.
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy' \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  sleep 0.5
  printf 'needs-decision [key=api]: REST or gRPC\nworking: writing the tests meanwhile\n' > "$status_file"
  wait_for_exit "$pid" 80 || fail "a still-open decision masked by a later working: line never surfaced"

  assert_grep "open-decision=api" "$out" "the wake did not carry the open decision it woke for"
  assert_grep "last=working: writing the tests meanwhile" "$out" \
    "the payload lost the last line (the fold is extra evidence, not a replacement)"
  pass "a still-open decision masked by a later line reaches the wake path"
}

test_open_decision_does_not_re_wake() {
  local dir state fakebin out pid status_file
  dir=$(make_case decision-once); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/do1.status"
  fm_write_meta "$state/do1.meta" "window=sess:fm-do1" "kind=ship"

  # Firstmate has already been woken for this decision and is thinking about it.
  printf 'needs-decision [key=api]: REST or gRPC\n' > "$status_file"
  printf '%s' "$(status_open_decision_sig "$status_file")" > "$state/.decision-seen-do1"
  printf '%s' "$(seen_sig "$status_file")" > "$state/.seen-do1_status"

  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy' \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  sleep 0.5
  # The crew keeps working while it waits. The decision is still open, but it is the
  # SAME decision: this must not wake firstmate again.
  printf 'working: writing the tests meanwhile\n' >> "$status_file"
  sleep 4
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [ ! -s "$out" ] || fail "an already-surfaced open decision re-woke firstmate: $(cat "$out")"
  pass "an open decision firstmate already has does not re-wake it on every later line"
}

test_idle_secondmate_stays_silent
test_wedged_secondmate_surfaces
test_secondmate_with_crew_of_its_own_counts_as_live_work
test_masked_open_decision_surfaces
test_open_decision_does_not_re_wake
