#!/usr/bin/env bash
# tests/fm-wake-payload.test.sh - the fat wake payload.
#
# A wake must carry the evidence the watcher already computed: the task id, the
# last status line, the absorb-class verdict, and idle age where known. Before
# this, a `stale:` wake was the bare string "stale: <window>" and a `signal:` wake
# was a bare file list, so handling either forced the orchestrator to re-read a
# status file the watcher had just held in a variable.
#
# Covers the pure payload grammar (fm-classify-lib.sh), the real watcher's
# surfaced signal/stale payloads end to end, and the daemon's target parse (which
# must cut the evidence off and still classify).
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-payload-tests)

watch_bg() {  # <state> <fakebin> <out> [extra env...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# --- pure grammar -----------------------------------------------------------

test_payload_grammar() {
  local dir state out
  dir=$(make_case payload-grammar); state="$dir/state"
  printf 'working: compiling\nneeds-decision: A or B\n' > "$state/t1.status"

  out=$(wake_payload stale "sess:fm-t1" "$state" t1 none)
  [ "$out" = "stale: sess:fm-t1 | task=t1 class=none last=needs-decision: A or B" ] \
    || fail "stale payload grammar drifted: $out"

  out=$(wake_payload stale "sess:fm-t1" "$state" working "idle=300s" "wedge=3" "demand-deep-inspection=1")
  assert_contains "$out" "idle=300s wedge=3 demand-deep-inspection=1 last=" "extra fields not carried in order"

  # A task with no status file at all still yields a well-formed payload.
  out=$(wake_payload stale "sess:fm-none" "$state" none-task none)
  assert_contains "$out" "last=(none)" "missing status file did not render last=(none)"

  # The target half is recoverable, so a consumer that only wants the window can
  # cut the evidence off.
  [ "$(wake_payload_target "sess:fm-t1 | task=t1 class=none last=x")" = "sess:fm-t1" ] \
    || fail "wake_payload_target did not cut at the evidence separator"
  [ "$(wake_payload_target "sess:fm-t1")" = "sess:fm-t1" ] \
    || fail "wake_payload_target mangled an evidence-free target"
  pass "wake_payload: one line, task + class + fields + last, target recoverable"
}

# --- the real watcher -------------------------------------------------------

test_signal_wake_carries_evidence() {
  local dir state fakebin out drain_out pid status_file
  dir=$(make_case payload-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/sig-p1.status"
  fm_write_meta "$state/sig-p1.meta" "window=sess:fm-sig-p1" "worktree=$dir" "kind=ship"

  FM_FAKE_CREW_STATE='state: needs-decision · source: status-log · A or B' \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  sleep 0.5
  printf 'needs-decision: pick A or B\n' > "$status_file"
  wait_for_exit "$pid" 80

  assert_grep "signal: $status_file | task=sig-p1 class=none" "$out" \
    "surfaced signal wake did not carry task and absorb verdict"
  assert_grep "last=needs-decision: pick A or B" "$out" \
    "surfaced signal wake did not carry the last status line"
  # The open-decision fold rides along: last= alone cannot say whether the question
  # is still unanswered (tests/fm-silent-holes.test.sh owns that contract).
  assert_grep "open-decision=default" "$out" "surfaced signal wake did not carry the open decision"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain failed"
  assert_grep "task=sig-p1 class=none" "$drain_out" "the queued record lost task/class"
  assert_grep "last=needs-decision: pick A or B" "$drain_out" \
    "the queued record lost the last status line"
  pass "signal wake carries task, absorb verdict, and last status line (queue included)"
}

test_stale_wake_carries_evidence() {
  local dir state fakebin out pid window capture
  dir=$(make_case payload-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/capture"
  window="sess:fm-stale-p2"
  fm_write_meta "$state/stale-p2.meta" "window=$window" "worktree=$dir" "kind=ship"
  printf 'working: running the suite\n' > "$state/stale-p2.status"
  printf '%s\n' 'idle pane' > "$capture"
  # Prime .seen-* so the pre-existing status does not fire the signal path first.
  printf '%s' "$(seen_sig "$state/stale-p2.status")" > "$state/.seen-stale-p2_status"

  FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · stopped' \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 120

  assert_grep "stale: $window | task=stale-p2 class=none last=working: running the suite" "$out" \
    "surfaced stale wake did not carry task/class/last evidence"
  pass "stale wake carries task, absorb verdict, and last status line"
}

# --- the daemon still parses the target ------------------------------------

test_daemon_parses_fat_payload() {
  local dir state window
  dir=$(make_case payload-daemon); state="$dir/state"
  window="sess:fm-dmn-p3"
  fm_write_meta "$state/dmn-p3.meta" "window=$window" "worktree=$dir" "kind=ship"
  printf 'done: PR https://example.invalid/pull/9\n' > "$state/dmn-p3.status"

  # The daemon's main loop is skipped under sourcing (BASH_SOURCE guard), so this
  # defines only its classifiers and handle_wake.
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  is_wake_reason "stale: $window | task=dmn-p3 class=none last=done: x" \
    || fail "a fat stale payload was not recognized as a wake reason"
  FM_STATE_OVERRIDE="$state" handle_wake "stale: $window | task=dmn-p3 class=none last=done: PR https://example.invalid/pull/9" "$state"
  assert_grep "done: PR https://example.invalid/pull/9" "$state/.subsuper-escalations" \
    "daemon did not escalate a terminal stale carried in a fat payload"
  assert_absent "$state/.subsuper-stale-dmn_p3" \
    "daemon treated the evidence suffix as part of the window and left a wedge marker"
  pass "daemon cuts the evidence off a fat payload and classifies the target"
}

test_payload_grammar
test_signal_wake_carries_evidence
test_stale_wake_carries_evidence
test_daemon_parses_fat_payload
