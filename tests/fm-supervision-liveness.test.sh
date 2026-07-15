#!/usr/bin/env bash
# tests/fm-supervision-liveness.test.sh - the ONE authoritative "is a live watcher
# supervising THIS home?" predicate, its agent-facing surface, and the daemon-leak
# CONTAINMENT guard.
#
# These are safety-critical process invariants (a race or an eviction may not
# reproduce through an e2e), so they run as focused real-process units in the
# serial tail, exactly like fm-watcher-lock.test.sh.
#
# What this file locks down, all reproduced by executing the real scripts:
#   1. A watcher OR daemon launched from one checkout must REFUSE a home lock that
#      belongs to a DIFFERENT firstmate checkout (the crew-worktree state leak) -
#      the exact vector by which a crewmate merely running the test suite could
#      silently switch off the primary's supervision of the whole fleet.
#   2. An explicit FM_STATE_OVERRIDE (every test) and a watcher run from its own
#      home both PASS the guard - the containment never breaks isolated runs.
#   3. The agent-facing predicate bin/fm-supervision-live.sh is honest when
#      invoked DIRECTLY (no hook payload): DOWN for a fresh beacon over no lock and
#      for a dead-pid lock, live only for a genuinely live, identity-matched lock.
#   4. THE regression: a live primary watcher SURVIVES a supervision run (watcher +
#      daemon, the leak vector fm-test.sh exercises) launched from a foreign
#      checkout against its home.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
LIVE="$ROOT/bin/fm-supervision-live.sh"
GUARD="$ROOT/bin/fm-guard.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"
BIN_CANON="$(cd "$ROOT/bin" && pwd)"

TMP_ROOT=$(fm_test_tmproot fm-supervision-liveness)

# A directory that IS its own firstmate checkout (carries bin/fm-watch.sh) but is
# NOT this test's running checkout - the shape of a real home whose supervision a
# watcher/daemon launched from a crew worktree must refuse to seize.
make_other_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/bin" "$home/state"
  : > "$home/bin/fm-watch.sh"   # marks it as its own, DISTINCT checkout
  printf '%s\n' "$home"
}

# Write a genuinely-healthy watcher lock into <state>: a live, identity-matched
# holder whose recorded watcher-path is this checkout's own fm-watch.sh (the path
# both fm_watcher_healthy and fm-supervision-live.sh compute).
write_healthy_lock() {  # <state> <fm-home> <pid> <identity>
  local state=$1 home=$2 pid=$3 identity=$4
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$BIN_CANON/fm-watch.sh" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
}

identity_of() {  # <pid>
  FM_STATE_OVERRIDE="$TMP_ROOT/.ident" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$1"
}

# --- CONTAINMENT: refuse a foreign home lock --------------------------------

test_watcher_refuses_foreign_home_lock() {
  local home sleeper identity out rc lock_pid
  home=$(make_other_home watcher-foreign)
  # A simulated live incumbent already supervising that home.
  sleep 60 &
  sleeper=$!
  identity=$(identity_of "$sleeper")
  write_healthy_lock "$home/state" "$home" "$sleeper" "$identity"
  # The foreign watcher runs from THIS checkout but is pointed (via FM_HOME, no
  # FM_STATE_OVERRIDE) at the other home's state - the crew-worktree leak.
  out=$(FM_HOME="$home" timeout 10 "$WATCH" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "foreign watcher did not refuse (exit $rc): $out"
  case "$out" in
    *"refusing foreign home lock"*) ;;
    *) fail "foreign watcher refusal lacked the explanatory message: $out" ;;
  esac
  lock_pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$sleeper" ] || fail "foreign watcher disturbed the incumbent's lock (pid now '$lock_pid', was '$sleeper')"
  is_live_non_zombie "$sleeper" || fail "foreign watcher killed the incumbent"
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  pass "watcher refuses a foreign home lock and leaves the incumbent's lock untouched"
}

test_daemon_refuses_foreign_home() {
  local home out rc
  home=$(make_other_home daemon-foreign)
  out=$(FM_HOME="$home" timeout 10 "$DAEMON" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "foreign daemon did not refuse (exit $rc): $out"
  case "$out" in
    *"refusing foreign home"*) ;;
    *) fail "foreign daemon refusal lacked the explanatory message: $out" ;;
  esac
  [ ! -e "$home/state/.supervise-daemon.lock" ] || fail "foreign daemon created a lock in the other home before refusing"
  pass "daemon refuses a foreign home before taking any lock"
}

test_state_override_exempts_the_guard() {
  # An explicit FM_STATE_OVERRIDE means state was deliberately redirected (every
  # test does this). The containment guard must NOT fire, or it would break every
  # isolated watcher run. With the override the watcher acquires the override lock
  # and enters its poll loop - so a bounded run times out (124), never exit 3.
  local home dir out rc
  home=$(make_other_home override-foreign-home)
  dir=$(make_case override-exempt)
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$dir/state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 2 "$WATCH" 2>&1); rc=$?
  case "$out" in
    *"refusing foreign home"*) fail "guard fired despite an explicit FM_STATE_OVERRIDE: $out" ;;
  esac
  # It passed the guard and blocked in its poll loop, so the bounded run is killed
  # by timeout (124) rather than refusing (3) - proof the override exempts it.
  [ "$rc" -eq 124 ] || fail "override watcher did not enter its poll loop (exit $rc, expected 124): $out"
  pass "an explicit FM_STATE_OVERRIDE exempts the containment guard (isolated runs unaffected)"
}

# --- AGENT-FACING PREDICATE: bin/fm-supervision-live.sh ---------------------

test_agent_predicate_down_on_fresh_beacon_no_lock() {
  local dir state out rc
  dir=$(make_case pred-orphan-beacon)
  state="$dir/state"
  : > "$state/task1.meta"
  touch "$state/.last-watcher-beat"   # orphaned beacon, NO lock
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$LIVE" 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "predicate did not report DOWN (exit $rc) for a fresh beacon with no lock: $out"
  case "$out" in
    *"DOWN"*) ;;
    *) fail "predicate did not print DOWN for an orphaned beacon: $out" ;;
  esac
  pass "fm-supervision-live: DOWN for a fresh beacon over no lock (invoked directly, no hook payload)"
}

test_agent_predicate_down_on_dead_lock() {
  local dir state dead out rc
  dir=$(make_case pred-dead-lock)
  state="$dir/state"
  : > "$state/task1.meta"
  dead=$(dead_pid)
  write_healthy_lock "$state" "$dir" "$dead" "dead watcher identity"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$LIVE" 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "predicate did not report DOWN (exit $rc) for a dead-pid lock: $out"
  case "$out" in *"DOWN"*) ;; *) fail "predicate did not print DOWN for a dead lock: $out" ;; esac
  pass "fm-supervision-live: DOWN for a dead-pid lock even with a fresh beacon"
}

test_agent_predicate_live_on_healthy_lock() {
  local dir state sleeper identity out rc
  dir=$(make_case pred-live-lock)
  state="$dir/state"
  : > "$state/task1.meta"
  sleep 60 &
  sleeper=$!
  identity=$(identity_of "$sleeper")
  write_healthy_lock "$state" "$dir" "$sleeper" "$identity"
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$LIVE" 2>&1); rc=$?
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "predicate did not report live (exit $rc) for a healthy lock: $out"
  case "$out" in
    *"live pid=$sleeper"*) ;;
    *) fail "predicate did not name the live holder: $out" ;;
  esac
  pass "fm-supervision-live: live for a genuinely live, identity-matched watcher lock"
}

# --- GUARD/TURN-END CONSISTENCY: the same arming tolerance ------------------

test_guard_tolerates_fresh_arming_marker() {
  # fm-guard.sh now decides liveness by home-lock ownership (like the turn-end
  # guard), so it must also tolerate a fresh state/.watch.arming marker - a normal
  # watcher handoff - or it would false-alarm on every re-arm. A STALE marker must
  # still surface the lapse. Both mirror bin/fm-turnend-guard.sh exactly.
  local dir state err
  dir=$(make_case guard-arming)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  touch "$state/.last-watcher-beat"   # fresh beacon, NO live lock (mid-handoff)
  : > "$state/.watch.arming"          # a re-arm actively in flight
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_GUARD_GRACE=300 FM_ARMING_GRACE=30 "$GUARD" 2> "$err" >/dev/null || fail "guard failed"
  ! grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "guard false-alarmed during an in-flight re-arm (fresh .watch.arming): $(cat "$err")"
  : > "$err"
  touch -t 202001010000 "$state/.watch.arming"   # stale marker: no real re-arm
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_GUARD_GRACE=300 FM_ARMING_GRACE=30 "$GUARD" 2> "$err" >/dev/null || fail "guard failed"
  grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "guard did not surface a lapse with a stale arming marker"
  pass "guard tolerates a fresh re-arm handoff and still surfaces a stale-marker lapse (consistent with the turn-end guard)"
}

# --- GUARD: the detached-vs-released banner distinction ----------------------

test_guard_silent_in_detached_only_home() {
  # A detached task is user-driven with no firstmate supervision, so a home
  # whose only task is detached demands no watcher: fm-guard.sh must raise NO
  # watcher-down banner even with no live lock. Before the FM_SUP_SUPERVISABLE
  # gate this false-alarmed on the raw recorded-task count.
  local dir state err
  dir=$(make_case guard-detached-only)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\nworktree=/wt/detached\ndetached=2026-07-15T12:00:00Z\ndetached_window=firstmate:fm-task\n' > "$state/task.meta"
  touch "$state/.last-watcher-beat"   # fresh beacon, NO live lock
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_GUARD_GRACE=300 FM_ARMING_GRACE=30 "$GUARD" 2> "$err" >/dev/null || fail "guard failed"
  ! grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "guard banner fired for a detached-only home (no watcher demanded): $(cat "$err")"
  pass "fm-guard: no watcher-down banner when the only in-flight task is detached"
}

test_guard_banners_in_released_only_home() {
  # A released task (crew gone, no window) still needs the watcher to poll its PR
  # CI, so it stays supervisable: fm-guard.sh MUST surface the lapse when no
  # watcher is live. Locks the detached-vs-released distinction on the banner path.
  local dir state err
  dir=$(make_case guard-released-only)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\nworktree=/wt/released\nreleased=2026-07-15T12:00:00Z\n' > "$state/task.meta"
  touch "$state/.last-watcher-beat"   # fresh beacon, NO live lock
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_GUARD_GRACE=300 FM_ARMING_GRACE=30 "$GUARD" 2> "$err" >/dev/null || fail "guard failed"
  grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "guard did not surface a lapse for a released (still-supervised) task: $(cat "$err")"
  pass "fm-guard: still banners a watcher-down lapse when the only task is released (not detached)"
}

# --- THE REGRESSION: a live primary survives a foreign supervision run ------

test_primary_watcher_survives_foreign_supervision_run() {
  # Reproduces the incident deterministically: a live primary watcher supervising
  # its own home, then the exact leak vector a crew running fm-test.sh exercises -
  # a real watcher AND a real daemon launched from a FOREIGN checkout ($ROOT)
  # pointed at the primary's home. Both must refuse, and the primary watcher must
  # neither self-evict nor lose its lock.
  local dir fakebin wpid i lock_pid out1 rc1 out2 rc2 beat_before beat_after
  dir=$(make_case regression-primary)
  fakebin="$dir/fakebin"
  # A genuine second checkout: the primary home carries its OWN copy of bin/, so
  # its watcher passes the containment guard while the foreign $ROOT watcher fails.
  cp -R "$ROOT/bin" "$dir/bin"
  # Start the real incumbent primary watcher in its own home.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$dir/bin/fm-watch.sh" >"$dir/watch.out" 2>"$dir/watch.err" &
  wpid=$!
  i=0
  while [ "$i" -lt 300 ]; do
    [ "$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] \
      && [ -e "$dir/state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] \
    || { kill "$wpid" 2>/dev/null || true; fail "incumbent primary watcher did not take its own lock: $(cat "$dir/watch.err" 2>/dev/null)"; }
  beat_before=$(cat "$dir/state/.watch.lock/pid-identity" 2>/dev/null || true)

  # The leak vector: foreign watcher, then foreign daemon, both from $ROOT.
  out1=$(FM_HOME="$dir" timeout 10 "$WATCH" 2>&1); rc1=$?
  out2=$(FM_HOME="$dir" timeout 10 "$DAEMON" 2>&1); rc2=$?

  lock_pid=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
  beat_after=$(cat "$dir/state/.watch.lock/pid-identity" 2>/dev/null || true)
  local alive=0
  is_live_non_zombie "$wpid" && alive=1
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true

  [ "$rc1" -eq 3 ] || fail "foreign watcher was not refused (exit $rc1): $out1"
  [ "$rc2" -eq 3 ] || fail "foreign daemon was not refused (exit $rc2): $out2"
  [ "$lock_pid" = "$wpid" ] || fail "primary lost its lock to the foreign supervision run (pid now '$lock_pid', was '$wpid')"
  [ "$beat_before" = "$beat_after" ] || fail "primary lock identity changed under the foreign run"
  [ "$alive" -eq 1 ] || fail "primary watcher self-evicted or died during the foreign supervision run"
  pass "a live primary watcher survives a watcher+daemon supervision run launched from a foreign checkout"
}

test_watcher_refuses_foreign_home_lock
test_daemon_refuses_foreign_home
test_state_override_exempts_the_guard
test_agent_predicate_down_on_fresh_beacon_no_lock
test_agent_predicate_down_on_dead_lock
test_agent_predicate_live_on_healthy_lock
test_guard_tolerates_fresh_arming_marker
test_guard_silent_in_detached_only_home
test_guard_banners_in_released_only_home
test_primary_watcher_survives_foreign_supervision_run
