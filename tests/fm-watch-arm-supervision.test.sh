#!/usr/bin/env bash
# tests/fm-watch-arm-supervision.test.sh - what bin/fm-watch-arm.sh is allowed to
# WAKE firstmate for.
#
# On a notify-on-exit harness the arm's exit IS the wake: every one of them costs a
# full model turn. The arm used to exit whenever its watcher stopped, wake reason or
# not, and a second arm attached to a live cycle instead of standing down - so one
# quiet watcher death became a notification, firstmate answered it with another arm,
# and the session accumulated ~80 live background tasks notifying each other every
# 3 seconds. docs/incidents/watch-arm-notification-storm.md has the evidence.
#
# The contract these cases lock down:
#   1. A watcher that dies with NOTHING to report is replaced in place. The arm
#      stays live and firstmate is never told.
#   2. A watcher wake reason still exits immediately, propagated verbatim.
#   3. Wake records the watcher enqueued but left no reason line for still exit -
#      queued work is information, and losing it was the other half of the bug.
#   4. Churn is bounded: a watcher that will not stay up ends as ONE loud FAILED
#      line, never an unbounded relaunch loop.
#   5. One arm per home: a second arm stands down instead of attaching, and
#      --restart stops the incumbent arm before taking over.
#   6. fm_arm_in_flight verifies a real live arm rather than trusting a marker's
#      mtime, so a long-lived arm is not misread as a blind turn.
#
# These background a real arm and bounded-wait on its behavior, so this file runs in
# bin/fm-test.sh's serial tail.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-arm-supervision)

# A self-contained firstmate home whose bin/ holds the REAL arm and lib next to a
# SCRIPTED stand-in watcher. The arm resolves its watcher as $SCRIPT_DIR/fm-watch.sh
# and validates the lock's recorded watcher-path and fm-home against its own, so the
# stand-in has to live in that bin/ to be confirmable at all.
make_arm_case() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/bin" "$dir/state"
  cp "$ROOT/bin/fm-watch-arm.sh" "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/"
  cat > "$dir/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
# Scripted stand-in for the watcher. It takes the singleton lock exactly the way
# the real one does (live pid + identity + fresh beacon), so the arm's honesty gate
# confirms it, then acts out one scenario from state/.fake-watch-mode:
#   quiet   - hold the lock briefly, release it, exit 0 saying nothing
#   wake    - release, then print one wake reason line
#   enqueue - append a durable wake record, release, say nothing
#   hold    - hold the lock until signalled
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-wake-lib.sh"
printf '%s\n' "$$" >> "$STATE/.fake-watch-runs"
mode=$(cat "$STATE/.fake-watch-mode" 2>/dev/null || echo quiet)
mkdir -p "$STATE/.watch.lock"
printf '%s\n' "$$" > "$STATE/.watch.lock/pid"
printf '%s\n' "$FM_HOME" > "$STATE/.watch.lock/fm-home"
printf '%s\n' "$SCRIPT_DIR/fm-watch.sh" > "$STATE/.watch.lock/watcher-path"
fm_pid_identity "$$" > "$STATE/.watch.lock/pid-identity"
touch "$STATE/.last-watcher-beat"
release() { rm -rf "$STATE/.watch.lock" 2>/dev/null || true; }
trap 'release; exit 143' TERM INT
sleep "${FAKE_WATCH_HOLD:-1}"
case "$mode" in
  wake) release; echo 'stale: fm-probe | class=none | idle=900s' ;;
  enqueue) fm_wake_append stale fm-probe 'stale: fm-probe | class=none | idle=900s'; release ;;
  hold) sleep 3600 ;;
  *) release ;;
esac
exit 0
SH
  chmod +x "$dir/bin/fm-watch.sh"
  printf '%s\n' "$dir"
}

set_mode() {  # <dir> <mode>
  printf '%s\n' "$2" > "$1/state/.fake-watch-mode"
}

watcher_runs() {  # <dir>
  [ -f "$1/state/.fake-watch-runs" ] || { echo 0; return 0; }
  wc -l < "$1/state/.fake-watch-runs" | tr -d ' '
}

wait_for_text() {  # <file> <text> [limit]
  local file=$1 text=$2 limit=${3:-300} i=0
  while [ "$i" -lt "$limit" ]; do
    grep -qF "$text" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Every case runs the arm from the case's own bin/ with its own home and state, so
# nothing here can see or disturb the running fleet's supervision. The home is pinned
# explicitly because tests/wake-helpers.sh exports one shared FM_ROOT_OVERRIDE for the
# whole file; inheriting it would point every case - and the watcher it starts - at the
# same state dir. The scripted watcher inherits these, so both ends agree on the home
# the singleton lock records.
run_arm() {  # <dir> [args...]
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_ARM_BACKOFF_MAX=1 FM_ARM_CONFIRM_TIMEOUT=6 FM_ARM_ATTACH_POLL=0.1 \
    "$dir/bin/fm-watch-arm.sh" "$@"
}

# Background an arm and set ARM_PID to the ARM's OWN pid. exec matters: without it
# $! is the wrapper subshell, and the arm's real pid - the one it writes into the
# arming marker and a second arm reports back - would never match what a case asserts.
ARM_PID=
run_arm_bg() {  # <dir> <outfile> [args...]
  local dir=$1 out=$2
  shift 2
  ( exec env FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
      FM_ARM_BACKOFF_MAX=1 FM_ARM_CONFIRM_TIMEOUT=6 FM_ARM_ATTACH_POLL=0.1 \
      "$dir/bin/fm-watch-arm.sh" "$@" ) > "$out" 2>&1 &
  ARM_PID=$!
}

test_quiet_watcher_death_does_not_wake_firstmate() {
  local dir armout armpid runs
  dir=$(make_arm_case quiet-relaunch)
  armout="$dir/arm.out"
  set_mode "$dir" quiet
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: relaunching after 1 quiet exit(s)' \
    || fail "arm did not relaunch a watcher that died with nothing to report: $(cat "$armout")"
  wait_for_text "$armout" 'watcher: started pid=' \
    || fail "arm never confirmed a watcher: $(cat "$armout")"
  is_live_non_zombie "$armpid" \
    || fail "arm EXITED on an information-free watcher death - that exit is a wasted firstmate turn: $(cat "$armout")"
  # The replacement is a genuinely new watcher process, not a re-report of the dead one.
  local i=0
  while [ "$i" -lt 300 ]; do
    runs=$(watcher_runs "$dir")
    [ -n "$runs" ] && [ "$runs" -ge 2 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -n "$runs" ] && [ "$runs" -ge 2 ] || fail "arm did not actually start a replacement watcher (runs=$runs)"
  grep -qF 'watcher: FAILED' "$armout" && fail "arm alarmed on a routine quiet death: $(cat "$armout")"
  # The churn is recorded where an investigation can find it later.
  grep -qF 'quiet=1' "$dir/state/.watch-arm.log" || fail "quiet relaunch was not recorded in state/.watch-arm.log"
  kill "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "a watcher that dies with nothing to report is relaunched in place, not reported"
}

test_watcher_wake_reason_still_exits() {
  local dir armout rc=0
  dir=$(make_arm_case wake-exit)
  armout="$dir/arm.out"
  set_mode "$dir" wake
  run_arm "$dir" > "$armout" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "arm did not exit zero on a real wake (status $rc): $(cat "$armout")"
  grep -qF 'stale: fm-probe | class=none | idle=900s' "$armout" \
    || fail "arm did not propagate the watcher's wake reason verbatim: $(cat "$armout")"
  pass "a watcher wake reason exits the arm and reaches firstmate verbatim"
}

test_queued_wakes_still_exit() {
  local dir armout rc=0
  dir=$(make_arm_case queued-exit)
  armout="$dir/arm.out"
  set_mode "$dir" enqueue
  run_arm "$dir" > "$armout" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "arm did not exit zero with queued wakes pending (status $rc): $(cat "$armout")"
  grep -qF 'watcher: wakes queued (1) - drain them' "$armout" \
    || fail "arm swallowed a queued wake record the watcher left behind: $(cat "$armout")"
  pass "wake records the watcher enqueued still reach firstmate when it left no reason line"
}

test_churn_is_bounded_by_one_loud_failure() {
  local dir armout rc=0
  dir=$(make_arm_case churn-budget)
  armout="$dir/arm.out"
  set_mode "$dir" quiet
  FM_ARM_RELAUNCH_MAX=2 run_arm "$dir" > "$armout" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "arm exited zero after exhausting its churn budget: $(cat "$armout")"
  grep -qF 'watcher: FAILED - watcher will not stay up' "$armout" \
    || fail "arm did not report the churn as one loud failure: $(cat "$armout")"
  [ "$(grep -c 'watcher: FAILED' "$armout")" -eq 1 ] \
    || fail "arm repeated its alarm instead of failing once: $(cat "$armout")"
  grep -qF 'see state/.watch-arm.log' "$armout" || fail "FAILED line did not point at the churn log"
  pass "a watcher that will not stay up ends as one loud failure, not a relaunch loop"
}

test_second_arm_stands_down_instead_of_attaching() {
  local dir armout secondout armpid rc=0 runs
  dir=$(make_arm_case one-arm-per-home)
  armout="$dir/arm.out"
  secondout="$dir/arm2.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' || fail "first arm never confirmed a watcher: $(cat "$armout")"
  run_arm "$dir" > "$secondout" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "second arm exited non-zero (status $rc): $(cat "$secondout")"
  grep -qF "watcher: already armed pid=$armpid" "$secondout" \
    || fail "second arm did not stand down for the live arm: $(cat "$secondout")"
  grep -qE 'watcher: (attached|started)' "$secondout" \
    && fail "second arm attached to the live cycle - that duplicate is what multiplied every wake: $(cat "$secondout")"
  runs=$(watcher_runs "$dir")
  [ "$runs" -eq 1 ] || fail "second arm started another watcher (runs=$runs)"
  is_live_non_zombie "$armpid" || fail "the incumbent arm died when a second one ran"
  kill "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "a second arm stands down for a live one instead of attaching to its cycle"
}

# The storm came back in the field through this hole: a short-lived arm's EXIT trap
# deleted the marker unconditionally, including when the marker belonged to a
# DIFFERENT arm that was still supervising. That arm then became invisible - the
# dedupe below stopped standing duplicates down and the turn-end guard stopped
# seeing a re-arm in flight, so firstmate declared supervision down and re-armed on
# a loop, exactly as before the fix.
test_exiting_arm_leaves_a_live_peers_marker_alone() {
  local dir armout armpid owner
  dir=$(make_arm_case marker-ownership)
  armout="$dir/arm.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' || fail "arm never confirmed a watcher: $(cat "$armout")"
  owner=$(sed -n 's/^pid=//p' "$dir/state/.watch.arming" 2>/dev/null | head -1)
  [ "$owner" = "$armpid" ] || fail "live arm does not own the marker (owner=$owner, arm=$armpid)"

  # A second arm stands down and exits. Its exit must not take the marker with it.
  run_arm "$dir" > "$dir/arm2.out" 2>&1 || fail "second arm exited non-zero: $(cat "$dir/arm2.out")"
  [ -e "$dir/state/.watch.arming" ] \
    || fail "a standing-down arm DELETED the live arm's marker on exit - the live arm is now invisible to the dedupe and to both guards"
  owner=$(sed -n 's/^pid=//p' "$dir/state/.watch.arming" 2>/dev/null | head -1)
  [ "$owner" = "$armpid" ] \
    || fail "the marker no longer names the live arm after a peer exited (owner=$owner, arm=$armpid)"
  is_live_non_zombie "$armpid" || fail "the live arm died"
  kill "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "an exiting arm leaves a live peer's arming marker intact"
}

# Self-heal: whatever removes the marker, a live arm must take it back on its own.
# Writing it only at startup means one deletion blinds the arm for the rest of its
# life, however long it supervises.
test_live_arm_retakes_a_deleted_marker() {
  local dir armout armpid i owner
  dir=$(make_arm_case marker-selfheal)
  armout="$dir/arm.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' || fail "arm never confirmed a watcher: $(cat "$armout")"
  rm -f "$dir/state/.watch.arming"
  i=0
  while [ "$i" -lt 100 ]; do
    owner=$(sed -n 's/^pid=//p' "$dir/state/.watch.arming" 2>/dev/null | head -1)
    [ "$owner" = "$armpid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$owner" = "$armpid" ] \
    || fail "the arm never re-took its deleted marker; it stays invisible for the rest of the cycle (owner=$owner, arm=$armpid)"
  kill "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "a live arm re-takes a marker that was deleted underneath it"
}

# The startup dedupe cannot fire when the marker is missing at the instant a second
# arm starts. It must not then attach to the live cycle anyway: two arms on one
# cycle is the multiplier that turned a single wake into ~80 background tasks.
test_second_arm_stands_down_even_when_the_marker_was_missing() {
  local dir armout secondout armpid rc=0 runs
  dir=$(make_arm_case one-arm-marker-race)
  armout="$dir/arm.out"
  secondout="$dir/arm2.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' || fail "first arm never confirmed a watcher: $(cat "$armout")"
  # Simulate losing the race: no marker at all when the second arm starts.
  rm -f "$dir/state/.watch.arming"
  # Backgrounded and bounded on purpose: the regression here is that the second arm
  # ATTACHES and waits forever, which as a foreground call would burn the whole file's
  # timeout and report nothing useful about why.
  local secondpid i=0
  run_arm_bg "$dir" "$secondout"
  secondpid=$ARM_PID
  while [ "$i" -lt 300 ] && is_live_non_zombie "$secondpid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if is_live_non_zombie "$secondpid"; then
    kill "$secondpid" 2>/dev/null || true
    wait "$secondpid" 2>/dev/null || true
    fail "second arm never exited - it attached to the live cycle and became a duplicate notification: $(cat "$secondout")"
  fi
  wait "$secondpid" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "second arm exited non-zero (status $rc): $(cat "$secondout")"
  grep -qF 'watcher: already armed' "$secondout" \
    || fail "second arm did not stand down once the race resolved: $(cat "$secondout")"
  grep -qF 'watcher: attached' "$secondout" \
    && fail "second arm ATTACHED to the live cycle - that duplicate is what multiplied every wake: $(cat "$secondout")"
  runs=$(watcher_runs "$dir")
  [ "$runs" -eq 1 ] || fail "second arm left an extra watcher behind (runs=$runs)"
  is_live_non_zombie "$armpid" || fail "the incumbent arm died when a second one ran"
  kill "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "a second arm stands down even when the marker was missing when it started"
}

test_restart_stops_the_incumbent_arm() {
  local dir armout restartout armpid restartpid i runs
  dir=$(make_arm_case restart-incumbent)
  armout="$dir/arm.out"
  restartout="$dir/restart.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' || fail "incumbent arm never confirmed a watcher: $(cat "$armout")"
  run_arm_bg "$dir" "$restartout" --restart
  restartpid=$ARM_PID
  i=0
  while [ "$i" -lt 300 ] && is_live_non_zombie "$armpid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$armpid" \
    || fail "--restart left the incumbent arm running; it would have relaunched the watcher we just stopped"
  wait "$armpid" 2>/dev/null || true
  wait_for_text "$restartout" 'watcher: started pid=' || fail "--restart did not own a fresh cycle: $(cat "$restartout")"
  runs=$(watcher_runs "$dir")
  [ "$runs" -ge 2 ] || fail "--restart did not start a fresh watcher (runs=$runs)"
  kill "$restartpid" 2>/dev/null || true
  wait "$restartpid" 2>/dev/null || true
  pass "--restart stops this home's incumbent arm before taking the cycle"
}

test_arm_in_flight_verifies_a_real_process() {
  # The guards ask this predicate whether a re-arm is genuinely in flight. A
  # long-lived arm's marker mtime says nothing about whether it is working, so a
  # live identity-matched arm must count however old its marker is - while an
  # orphan marker left by a SIGKILLed arm must still expire.
  local dir state arm_path live marker identity
  dir=$(make_arm_case in-flight-predicate)
  state="$dir/state"
  arm_path="$dir/bin/fm-watch-arm.sh"
  marker="$state/.watch.arming"
  sleep 300 &
  live=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live") \
    || fail "could not identify the stand-in arm pid"
  ask_in_flight() {  # <grace>
    FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_arm_in_flight "$2" "$3" "$4" "$5"' \
      _ "$LIB" "$state" "$arm_path" "$1" "$dir"
  }
  {
    printf 'pid=%s\n' "$live"
    printf 'identity=%s\n' "$identity"
    printf 'arm-path=%s\n' "$arm_path"
    printf 'fm-home=%s\n' "$dir"
  } > "$marker"
  touch -t 200001010000 "$marker"
  ask_in_flight 30 || fail "a live, identity-matched arm was not counted as in flight once its marker aged"
  # Same marker, dead arm: the fallback window is all that is left, and it expires.
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  ask_in_flight 30 && fail "a dead arm's stale marker still read as a re-arm in flight"
  touch "$marker"
  ask_in_flight 30 || fail "a freshly-written unverifiable marker was not tolerated inside its grace"
  rm -f "$marker"
  ask_in_flight 30 && fail "an absent marker read as a re-arm in flight"
  pass "fm_arm_in_flight verifies a live arm process and expires an orphan marker"
}

test_quiet_watcher_death_does_not_wake_firstmate
test_watcher_wake_reason_still_exits
test_queued_wakes_still_exit
test_churn_is_bounded_by_one_loud_failure
test_second_arm_stands_down_instead_of_attaching
test_exiting_arm_leaves_a_live_peers_marker_alone
test_live_arm_retakes_a_deleted_marker
test_second_arm_stands_down_even_when_the_marker_was_missing
test_restart_stops_the_incumbent_arm
test_arm_in_flight_verifies_a_real_process
