#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

# fm_pid_alive, so watcher liveness is asserted with the production predicate
# instead of a re-rolled one. Sourcing this lib is NOT free: it resolves a home
# and runs `mkdir -p "$STATE"` (bin/fm-wake-lib.sh:16), which lands in the
# CHECKOUT when nothing overrides it - the same hazard bin/fm-watch-checkpoint.sh
# avoids by sourcing only the side-effect-free kind lib. Aim it at the temp root
# first. The override stays UNEXPORTED and is dropped straight after, so it can
# never reach the checkpoints spawned below, which must resolve their own homes.
FM_STATE_OVERRIDE="$TMP_ROOT/lib-state"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
unset FM_STATE_OVERRIDE

# A FRESH home makes the watcher's disk guard due on its very first cycle:
# age_of() reports a missing state/.last-disk-guard as 999999s old
# (bin/fm-watch.sh:506, :1063). The guard is not a probe - bin/fm-disk-guard.sh
# sweeps the REAL filesystem, and under host disk pressure it emits an actionable
# `disk-guard` wake that the checkpoint passes through INSTEAD of the wake the
# case wrote. That ambient host state, not a tight tolerance, is what made this
# file fail a different assertion on every run. Stamping the marker makes it
# not due for the whole window.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  touch "$home/state/.last-disk-guard"
  printf '%s\n' "$home"
}

# FM_DISK_GUARD_INTERVAL and FM_HEARTBEAT pin the janitor cadences so an exported
# value cannot make one due inside the window. FM_POOL_WARM=0 because .last-check
# is missing too, so the check sweep runs on cycle 1 of every case and would
# otherwise detach a real fm-pool-warm.sh against the shared worktree pool.
# FM_CHECK_INTERVAL is deliberately absent: each case sets its own, and it is the
# one knob a case uses to steer the watcher.
WATCH_ENV=(FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999
           FM_DISK_GUARD_INTERVAL=999999 FM_POOL_WARM=0)

# The window for the cases whose contract is PASS-THROUGH rather than the
# deadline. Derived from the suite's own hang bound, never tuned until these went
# green: the wake must cross a watcher startup, a poll, a SIGNAL_GRACE and a
# payload build, and on a box with more runnable work than cores that aggregate
# fork latency beats any budget this file could pick - raising it does not remove
# the race, it only chooses which loaded box loses it. bin/fm-test.sh's
# FM_TEST_TIMEOUT already reports a wedged file as one named TIMEOUT, so a case
# that never gets its wake still fails attributably; dividing by three keeps the
# three cases that use it inside that single budget. None of them WAITS this
# long - each returns the moment its wake fires.
CHECKPOINT_WINDOW=$(( ${FM_TEST_TIMEOUT:-300} / 3 ))

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" env "${WATCH_ENV[@]}" FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  # The contract is that no LIVE watcher outlives the checkpoint - NOT that the lock
  # DIRECTORY is gone, which is what this used to wait up to 10s for. The two differ:
  # `timeout` TERMs the watcher, and bash runs an EXIT trap on SIGTERM only most of
  # the time (measured 10 misses in 200 on bash 5.2.21), so fm_lock_release is
  # sometimes skipped and the dir left behind. Nobody can make that deterministic
  # from here, and it does not need to be: the debris is inert, because fm_pid_alive
  # gates every reader of the lock - fm_watcher_healthy calls a dead-pid lock
  # unhealthy and fm_lock_try_acquire steals it. Waiting on the directory WAS the
  # non-determinism, not evidence of it.
  #
  # Liveness needs no wait, so on the timeout(1)/gtimeout path this is an ordering
  # the machine cannot violate: the watcher is reaped before 124 is returned, so any
  # pid still recorded is already dead. The perl fallback
  # (bin/fm-watch-checkpoint.sh:70) signals the group and exits without waitpid, so
  # there this is a race - but one that can only fail LOUDLY, never pass silently.
  local held
  held=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
  ! fm_pid_alive "$held" \
    || fail "a live watcher (pid $held) outlived the quiet checkpoint's timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live watcher"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained signaller
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  # Signal the watcher only once it is provably INSIDE its poll loop, so the wake
  # lands within the checkpoint window instead of at a guessed offset from the
  # checkpoint's start. .last-watcher-beat is the watcher's own liveness beacon,
  # touched at the top of every cycle (bin/fm-watch.sh:682) - state the watcher wrote,
  # not a clock this test races.
  (
    waited=0
    while [ ! -e "$home/state/.last-watcher-beat" ] && [ "$waited" -lt 600 ]; do
      sleep 0.05
      waited=$((waited + 1))
    done
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  signaller=$!
  status=0
  FM_HOME="$home" env "${WATCH_ENV[@]}" FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds "$CHECKPOINT_WINDOW" >"$out" 2>"$err" || status=$?
  wait "$signaller"
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod +x "$home/state/env-check.check.sh"
  status=0
  FM_HOME="$home" env "${WATCH_ENV[@]}" FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds "$CHECKPOINT_WINDOW" >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for the foreground fm-watch.sh"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds "$CHECKPOINT_WINDOW" >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
