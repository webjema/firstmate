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
#   5. One arm per home: a second arm neither attaches to the live cycle nor exits.
#      It stands by, silent and live, and takes supervision over when the arm it
#      stood by for is gone. --restart stops the incumbent arm before taking over.
#   6. fm_arm_in_flight verifies a real live arm rather than trusting a marker's
#      mtime, so a long-lived arm is not misread as a blind turn.
#   7. A CONFIRMED watcher survives the arm that started it. The harness reaps this
#      process as one of its own background tasks - 157 of 196 arms over 15 days
#      died that way - and the traps used to take the watcher with them, so every
#      reap was a silent supervision outage. Nothing is lost by sparing it: the
#      watcher enqueues each wake before printing it, so the next arm adopts it and
#      the queue is drained. --restart still stops supervision deliberately.
#
# These background a real arm and bounded-wait on its behavior, so this file runs in
# bin/fm-test.sh's serial tail.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-arm-supervision)

# A scripted watcher now OUTLIVES the arm that started it, by design, and a case
# that fails leaves its arm mid-cycle, so nothing reaps either once a case ends.
# Match on the command line naming THIS run's temp root rather than on recorded
# pids: it covers arms, watchers and launchers alike, and a recycled pid can never
# be mistaken for one of ours. The runner's own command line does not name the temp
# root, so it cannot reap itself.
reap_case_processes() {
  local pid args
  while read -r pid args; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "$$" ] && continue
    case "$args" in
      *"$TMP_ROOT"*) kill -9 "$pid" 2>/dev/null || true ;;
    esac
  done < <(ps -eo pid=,args= 2>/dev/null || true)
}
trap 'reap_case_processes; fm_test_cleanup' EXIT

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
#   hold    - hold the lock and beat until signalled. The sleep is interruptible so
#             a TERM lands NOW: bash defers a trap until the running foreground
#             command finishes, and a watcher that ignores TERM for an hour would
#             make "--restart takes the old watcher down" untestable.
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
  hold) while :; do touch "$STATE/.last-watcher-beat"; sleep 1 & wait $! 2>/dev/null || true; done ;;
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

# The pid the arm CONFIRMED, read back from the one line that only ever names a
# confirmed watcher.
confirmed_watcher_pid() {  # <arm-output>
  sed -n 's/^watcher: started pid=\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1
}

# The production liveness gate, asked exactly as bin/fm-guard.sh asks it: this is
# what decides whether firstmate is told supervision is off.
watcher_healthy() {  # <dir>
  FM_STATE_OVERRIDE="$1/state" bash -c \
    '. "$1"; fm_watcher_healthy "$2/state" "$2/bin/fm-watch.sh" 300 "$2"' _ "$LIB" "$1"
}

pgid_of() {  # <pid>
  ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '
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
    FM_ARM_STANDBY_POLL=0.2 FM_ARM_STANDBY_SETTLE=0.2 \
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
      FM_ARM_STANDBY_POLL=0.2 FM_ARM_STANDBY_SETTLE=0.2 \
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

# The 2026-08-12 recurrence, in one case. The one-arm-per-home fix stopped the
# fan-out by making a duplicate arm print "already armed" and EXIT AT ONCE - and on
# this harness an immediate exit is an immediate wake. Firstmate answered that wake
# by arming, that arm exited at once too, and the terminal filled every ~15 seconds
# with a completion notification carrying no news. A duplicate has to satisfy BOTH
# halves: it must not attach (that is the fan-out) and it must not exit (that is the
# wake). Standing by, silent and live, is the only answer that does both.
test_second_arm_stands_by_instead_of_exiting() {
  local dir armout secondout armpid secondpid runs i
  dir=$(make_arm_case one-arm-per-home)
  armout="$dir/arm.out"
  secondout="$dir/arm2.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' || fail "first arm never confirmed a watcher: $(cat "$armout")"
  run_arm_bg "$dir" "$secondout"
  secondpid=$ARM_PID
  wait_for_text "$secondout" "watcher: standby - supervision held by arm pid=$armpid" \
    || fail "second arm did not stand by for the live arm: $(cat "$secondout")"
  # Well past the point where an exiting duplicate would already have notified.
  i=0
  while [ "$i" -lt 20 ]; do
    is_live_non_zombie "$secondpid" \
      || fail "second arm EXITED with nothing to say - that exit IS the wake firstmate answers with another arm: $(cat "$secondout")"
    sleep 0.1
    i=$((i + 1))
  done
  grep -qE 'watcher: (attached|started)' "$secondout" \
    && fail "second arm attached to the live cycle - that duplicate is what multiplied every wake: $(cat "$secondout")"
  runs=$(watcher_runs "$dir")
  [ "$runs" -eq 1 ] || fail "second arm started another watcher (runs=$runs)"
  is_live_non_zombie "$armpid" || fail "the incumbent arm died when a second one ran"
  kill "$secondpid" "$armpid" 2>/dev/null || true
  wait "$secondpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "a second arm stands by, live and silent, instead of exiting into a wake with no news"
}

# Standing by is only safe if it also hands supervision on. A parked arm waits on
# the incumbent ARM, not on its watcher cycle: when that arm is gone the standby
# takes the marker and holds a watcher up in its place, which is what keeps
# bin/fm-supervision-live.sh answering "live" across the handover.
# The incumbent's watcher outlives the incumbent now, so "holds a watcher up in its
# place" means ADOPTING that one - starting a second beside it would be the
# duplicate the whole file exists to prevent.
test_standby_takes_over_when_the_incumbent_arm_ends() {
  local dir armout secondout armpid secondpid runs owner i
  dir=$(make_arm_case standby-takeover)
  armout="$dir/arm.out"
  secondout="$dir/arm2.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' || fail "first arm never confirmed a watcher: $(cat "$armout")"
  run_arm_bg "$dir" "$secondout"
  secondpid=$ARM_PID
  wait_for_text "$secondout" 'watcher: standby - supervision held by arm' \
    || fail "second arm did not stand by: $(cat "$secondout")"
  kill "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  wait_for_text "$secondout" 'watcher: attached pid=' \
    || fail "the standby never took supervision over from the arm it was standing by for: $(cat "$secondout")"
  is_live_non_zombie "$secondpid" || fail "the promoted arm exited instead of supervising: $(cat "$secondout")"
  i=0
  while [ "$i" -lt 100 ]; do
    owner=$(sed -n 's/^pid=//p' "$dir/state/.watch.arming" 2>/dev/null | head -1)
    [ "$owner" = "$secondpid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$owner" = "$secondpid" ] \
    || fail "the promoted arm does not own the marker, so both guards still read supervision as unheld (owner=$owner, arm=$secondpid)"
  runs=$(watcher_runs "$dir")
  [ "$runs" -eq 1 ] || fail "the promoted arm started a second watcher beside the one that outlived its arm (runs=$runs)"
  watcher_healthy "$dir" || fail "supervision was not held across the handover"
  kill "$secondpid" 2>/dev/null || true
  wait "$secondpid" 2>/dev/null || true
  pass "a standby takes supervision over when the arm it stood by for is gone"
}

# The storm came back in the field through this hole: a short-lived arm's EXIT trap
# deleted the marker unconditionally, including when the marker belonged to a
# DIFFERENT arm that was still supervising. That arm then became invisible - the
# dedupe below stopped standing duplicates down and the turn-end guard stopped
# seeing a re-arm in flight, so firstmate declared supervision down and re-armed on
# a loop, exactly as before the fix.
test_exiting_arm_leaves_a_live_peers_marker_alone() {
  local dir armout armpid secondpid owner
  dir=$(make_arm_case marker-ownership)
  armout="$dir/arm.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' || fail "arm never confirmed a watcher: $(cat "$armout")"
  owner=$(sed -n 's/^pid=//p' "$dir/state/.watch.arming" 2>/dev/null | head -1)
  [ "$owner" = "$armpid" ] || fail "live arm does not own the marker (owner=$owner, arm=$armpid)"

  # A second arm parks and is then killed. Neither the parking nor the death may
  # take the live arm's marker with it.
  run_arm_bg "$dir" "$dir/arm2.out"
  secondpid=$ARM_PID
  wait_for_text "$dir/arm2.out" 'watcher: standby - supervision held by arm' \
    || fail "second arm did not stand by: $(cat "$dir/arm2.out")"
  kill "$secondpid" 2>/dev/null || true
  wait "$secondpid" 2>/dev/null || true
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
test_second_arm_stands_by_even_when_the_marker_was_missing() {
  local dir armout secondout armpid secondpid runs owner
  dir=$(make_arm_case one-arm-marker-race)
  armout="$dir/arm.out"
  secondout="$dir/arm2.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' || fail "first arm never confirmed a watcher: $(cat "$armout")"
  # Simulate losing the race: no marker at all when the second arm starts.
  rm -f "$dir/state/.watch.arming"
  run_arm_bg "$dir" "$secondout"
  secondpid=$ARM_PID
  wait_for_text "$secondout" "watcher: standby - supervision held by arm pid=$armpid" \
    || fail "second arm did not stand by once the race resolved: $(cat "$secondout")"
  grep -qF 'watcher: attached' "$secondout" \
    && fail "second arm ATTACHED to the live cycle - that duplicate is what multiplied every wake: $(cat "$secondout")"
  is_live_non_zombie "$secondpid" \
    || fail "second arm exited instead of parking - that exit is a wake with no news: $(cat "$secondout")"
  runs=$(watcher_runs "$dir")
  [ "$runs" -eq 1 ] || fail "second arm left an extra watcher behind (runs=$runs)"
  # The marker it took during the race went back to the arm that is really supervising.
  owner=$(sed -n 's/^pid=//p' "$dir/state/.watch.arming" 2>/dev/null | head -1)
  [ "$owner" = "$armpid" ] \
    || fail "the marker does not name the supervising arm after the race (owner=$owner, arm=$armpid)"
  is_live_non_zombie "$armpid" || fail "the incumbent arm died when a second one ran"
  kill "$secondpid" "$armpid" 2>/dev/null || true
  wait "$secondpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "a second arm stands by even when the marker was missing when it started"
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

# The 2026-08-16 outage, in one case. The harness reaps this arm as one of its own
# background tasks - it did so to 157 of 196 arms over 15 days - and the arm's
# signal traps answered by SIGTERMing the watcher they had started. Every reap was
# therefore a silent supervision outage, and firstmate only found out when the
# turn-end guard fired. A confirmed watcher is not the arm's to take down: it holds
# the lock, beats on its own, and has already enqueued every wake it has.
test_reaped_arm_leaves_its_confirmed_watcher_supervising() {
  local dir armout secondout armpid secondpid watcher runs i
  dir=$(make_arm_case reaped-arm)
  armout="$dir/arm.out"
  secondout="$dir/arm2.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' || fail "arm never confirmed a watcher: $(cat "$armout")"
  watcher=$(confirmed_watcher_pid "$armout")
  [ -n "$watcher" ] || fail "could not read the confirmed watcher's pid: $(cat "$armout")"

  # The reap. Watch the watcher for well past the point where a kill sent on the
  # arm's way out would have landed - checking once, immediately, races it.
  kill -TERM "$armpid" 2>/dev/null || true
  wait_for_exit "$armpid" 100
  i=0
  while [ "$i" -lt 20 ]; do
    is_live_non_zombie "$watcher" \
      || fail "the arm killed its own confirmed watcher on the way out - every harness reap is a silent supervision outage"
    sleep 0.1
    i=$((i + 1))
  done
  watcher_healthy "$dir" \
    || fail "the surviving watcher does not pass the guards' liveness gate, so supervision still reads as off"

  # And supervision costs nothing to resume: the next arm adopts the survivor.
  run_arm_bg "$dir" "$secondout"
  secondpid=$ARM_PID
  wait_for_text "$secondout" "watcher: attached pid=$watcher" \
    || fail "the next arm did not adopt the watcher that outlived its arm: $(cat "$secondout")"
  runs=$(watcher_runs "$dir")
  [ "$runs" -eq 1 ] || fail "the next arm started a second watcher instead of adopting the live one (runs=$runs)"
  kill "$secondpid" 2>/dev/null || true
  wait "$secondpid" 2>/dev/null || true
  pass "a reaped arm leaves its confirmed watcher supervising, and the next arm adopts it"
}

# Sparing a confirmed watcher must not blunt the DELIBERATE stop. --restart takes
# supervision down by signalling the pids this home recorded, not through the
# signal traps, so it still replaces a healthy watcher with a fresh one.
test_restart_still_takes_the_old_watcher_down() {
  local dir armout restartout armpid restartpid watcher fresh i
  dir=$(make_arm_case restart-stops-watcher)
  armout="$dir/arm.out"
  restartout="$dir/restart.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' || fail "incumbent arm never confirmed a watcher: $(cat "$armout")"
  watcher=$(confirmed_watcher_pid "$armout")
  [ -n "$watcher" ] || fail "could not read the confirmed watcher's pid: $(cat "$armout")"
  run_arm_bg "$dir" "$restartout" --restart
  restartpid=$ARM_PID
  i=0
  while [ "$i" -lt 300 ] && is_live_non_zombie "$watcher"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$watcher" \
    || fail "--restart left the old watcher running; a deliberate stop that stops nothing is worse than none"
  wait_for_text "$restartout" 'watcher: started pid=' || fail "--restart did not own a fresh cycle: $(cat "$restartout")"
  fresh=$(confirmed_watcher_pid "$restartout")
  [ -n "$fresh" ] && [ "$fresh" != "$watcher" ] || fail "--restart re-reported the old watcher instead of a fresh one (old=$watcher, new=$fresh)"
  kill "$restartpid" 2>/dev/null || true
  wait "$restartpid" 2>/dev/null || true
  pass "--restart still takes this home's watcher down and replaces it"
}

# The worse shape of the same reap: the harness signals the arm's whole process
# GROUP. Sparing the child is no defence there - a same-group watcher dies with the
# arm however careful the trap is - so the watcher gets its own session.
# The arm runs under a launcher that is itself a session leader, which is both how a
# harness background task is really shaped (the arm is a plain `&` child, not a
# group leader) and the only way the group kill below cannot escape into the runner.
test_watcher_survives_a_process_group_reap() {
  local dir armout launcher armpid watcher arm_pgid watcher_pgid i
  if ! command -v setsid >/dev/null 2>&1; then
    pass "containing a process-group reap needs setsid, which this box does not have - skipped"
    return 0
  fi
  dir=$(make_arm_case pgroup-reap)
  armout="$dir/arm.out"
  launcher="$dir/launch.sh"
  set_mode "$dir" hold
  cat > "$launcher" <<SH
#!/usr/bin/env bash
FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \\
  FM_ARM_BACKOFF_MAX=1 FM_ARM_CONFIRM_TIMEOUT=6 FM_ARM_ATTACH_POLL=0.1 \\
  FM_ARM_STANDBY_POLL=0.2 FM_ARM_STANDBY_SETTLE=0.2 \\
  "$dir/bin/fm-watch-arm.sh" > "$armout" 2>&1 &
printf '%s\n' "\$!" > "$dir/armpid"
wait
SH
  setsid bash "$launcher" >/dev/null 2>&1 &
  wait_for_text "$armout" 'watcher: started pid=' || fail "arm never confirmed a watcher: $(cat "$armout" 2>/dev/null)"
  armpid=$(cat "$dir/armpid" 2>/dev/null)
  watcher=$(confirmed_watcher_pid "$armout")
  [ -n "$armpid" ] && [ -n "$watcher" ] || fail "could not read the arm and watcher pids (arm=$armpid, watcher=$watcher)"
  arm_pgid=$(pgid_of "$armpid")
  watcher_pgid=$(pgid_of "$watcher")
  [ -n "$arm_pgid" ] || fail "could not read the arm's process group"
  [ "$watcher_pgid" != "$arm_pgid" ] \
    || fail "the watcher shares the arm's process group ($arm_pgid), so a group-wide reap takes supervision with it"
  # Refuse to fire a group kill that could reach this runner. It cannot, because the
  # launcher is a session leader - but a wrong pgid here would kill the suite.
  [ "$arm_pgid" != "$(pgid_of $$)" ] || fail "refusing to reap: the arm shares THIS test runner's process group"

  kill -TERM -"$arm_pgid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 100 ] && is_live_non_zombie "$armpid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$armpid" || fail "the group reap did not reach the arm, so this case proves nothing"
  i=0
  while [ "$i" -lt 20 ]; do
    is_live_non_zombie "$watcher" \
      || fail "a process-group reap of the arm took the watcher with it"
    sleep 0.1
    i=$((i + 1))
  done
  watcher_healthy "$dir" || fail "the surviving watcher does not pass the guards' liveness gate"
  pass "a watcher in its own session survives a process-group reap of its arm"
}

# setsid EXECS when it can and FORKS when its caller already leads its process
# group, and in the fork case the pid the arm captured is the setsid process, not
# the watcher. The arm deliberately does NOT re-point at the pid the lock names:
# nothing distinguishes "the watcher setsid forked away from me" from "an orphan
# watcher that was already here", so re-pointing let an arm claim a stranger's
# watcher as its own child and then supervise it down the own-child loop instead
# of attach_and_wait, blind to a lock steal. The fork case must therefore be
# judged on its outcome, not on which line the arm prints: one watcher, adopted,
# passing the liveness gate, and still up after this arm is reaped.
test_arm_supervises_a_watcher_setsid_forked_away() {
  local dir armout armpid watcher runs i
  dir=$(make_arm_case setsid-forked)
  armout="$dir/arm.out"
  set_mode "$dir" hold
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/setsid" <<'SH'
#!/usr/bin/env bash
# `setsid --fork` in miniature: the pid the caller captures exits at once and the
# real command is reparented away from it.
"$@" &
exit 0
SH
  chmod +x "$dir/fakebin/setsid"
  ( exec env PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" \
      FM_STATE_OVERRIDE="$dir/state" FM_ARM_BACKOFF_MAX=1 FM_ARM_CONFIRM_TIMEOUT=6 \
      FM_ARM_ATTACH_POLL=0.1 "$dir/bin/fm-watch-arm.sh" ) > "$armout" 2>&1 &
  armpid=$!
  wait_for_text "$armout" 'watcher: attached pid=' \
    || fail "the arm did not adopt the watcher setsid forked away from it: $(cat "$armout")"
  grep -q 'watcher: FAILED' "$armout" \
    && fail "the arm burned its confirm timeout beside a live watcher: $(cat "$armout")"
  watcher=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null)
  [ -n "$watcher" ] || fail "no watcher holds the lock after setsid forked: $(cat "$armout")"
  runs=$(watcher_runs "$dir")
  [ "$runs" -eq 1 ] || fail "the arm started more than one watcher (runs=$runs)"
  watcher_healthy "$dir" || fail "the adopted watcher does not pass the guards' liveness gate"
  kill -TERM "$armpid" 2>/dev/null || true
  wait_for_exit "$armpid" 100
  i=0
  while [ "$i" -lt 20 ]; do
    is_live_non_zombie "$watcher" \
      || fail "reaping the arm took down the watcher it had adopted"
    sleep 0.1
    i=$((i + 1))
  done
  pass "a watcher setsid forked away is adopted, supervised, and survives the arm's reap"
}

# Diagnostic, not a fix: the traps used to exit without a word, which is why 157
# kills over 15 days left not one line in state/.watch-arm.log and the outage was
# invisible until someone counted the corpses. One line, naming the signal and
# whether supervision survived, is what would have identified this on day one.
test_a_reaped_arm_records_the_signal_that_killed_it() {
  local dir armout armpid watcher
  dir=$(make_arm_case reap-forensics)
  armout="$dir/arm.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' || fail "arm never confirmed a watcher: $(cat "$armout")"
  watcher=$(confirmed_watcher_pid "$armout")
  kill -TERM "$armpid" 2>/dev/null || true
  wait_for_exit "$armpid" 100
  wait_for_text "$dir/state/.watch-arm.log" "signal: TERM - watcher pid=$watcher confirmed=1" 50 \
    || fail "a reaped arm left no record of the signal or of whether supervision survived it: $(cat "$dir/state/.watch-arm.log" 2>/dev/null)"
  grep -qE 'signal: TERM' "$armout" \
    && fail "the death record reached firstmate's wake instead of staying in the churn log: $(cat "$armout")"
  pass "a reaped arm records the signal that killed it and whether its watcher survived"
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
test_second_arm_stands_by_instead_of_exiting
test_standby_takes_over_when_the_incumbent_arm_ends
test_exiting_arm_leaves_a_live_peers_marker_alone
test_live_arm_retakes_a_deleted_marker
test_second_arm_stands_by_even_when_the_marker_was_missing
test_restart_stops_the_incumbent_arm
test_reaped_arm_leaves_its_confirmed_watcher_supervising
test_restart_still_takes_the_old_watcher_down
test_watcher_survives_a_process_group_reap
test_arm_supervises_a_watcher_setsid_forked_away
test_a_reaped_arm_records_the_signal_that_killed_it
test_arm_in_flight_verifies_a_real_process
