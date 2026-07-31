#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background). Run it as its own
# standalone background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
# On a harness with a PreToolUse-equivalent hook, bin/fm-arm-pretool-check.sh
# applies the command-position policy before the command runs; see
# docs/arm-pretool-check.md for the blessed tree and deny reason codes. It is a
# pre-execution seatbelt, not a substitute for the verification here.
#
# THIS PROCESS'S EXIT IS A WAKE. On a notify-on-exit harness every exit costs
# firstmate a full turn, so this script exits ONLY when it has something
# firstmate must act on:
#   - a watcher wake reason (signal:/stale:/check:/heartbeat), propagated verbatim;
#   - queued wake records the watcher enqueued but no arm was left to propagate;
#   - one loud, bounded FAILED line when supervision genuinely cannot be held up.
# A watcher that dies with NOTHING to report is not news: this script relaunches
# it in place, with exponential backoff and a bounded churn budget, and stays
# live. That is the difference between one diagnostic and an unbounded
# conversation-spam loop - see docs/incidents/watch-arm-notification-storm.md.
#
# It forks the watcher as a tracked child, then VERIFIES the outcome before it
# settles in. It confirms a watcher process is genuinely alive AND the liveness
# beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the single
# source of truth, shared with fm-watch.sh and fm-guard.sh), and prints exactly
# one unambiguous status line per cycle:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: attached pid=<N> (beacon <age>s)            - arm mode adopted a live+fresh
#                                                          watcher holding the lock and
#                                                          waits until that cycle ends
#   watcher: healthy pid=<N> (beacon <age>s)             - restart mode found a live+fresh
#                                                          watcher it did not own
#   watcher: already armed pid=<N> (<watcher state>)     - another arm process is alive and
#                                                          owns supervision; do NOT arm again
#   watcher: relaunching after <k> quiet exit(s)         - a watcher died with nothing to
#                                                          report and is being replaced in place
#   watcher: wakes queued (<n>) - drain them             - the watcher enqueued records but
#                                                          left no reason line behind
#   watcher: FAILED - <reason>                             - could not hold a watcher up
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns a FAILED line. A live cycle already present means re-arm ADOPTS it - it
# never starts a second watcher.
#
# ONE ARM PER HOME. A second arm launched while a live, identity-matched arm
# already holds state/.watch.arming stands down immediately with the "already
# armed" line instead of attaching. Attaching duplicates instead multiplied every
# single wake into one notification per attached arm, each of which firstmate
# answered with another arm.
#
# --restart: stop ONLY this FM_HOME's supervision (the arm recorded in THIS home's
# state/.watch.arming and the watcher pid recorded in THIS home's
# state/.watch.lock) and own a fresh cycle, or report restart-only healthy if a
# live peer still holds the lock after the duplicate child stands down. It
# resolves and signals exactly those pids, so it can never touch another home's
# supervision. NEVER `pkill -f bin/fm-watch.sh`: that pattern matches every
# firstmate home's watcher (secondmate homes run the same script) and would kill
# siblings. Restart never takes the adopt path on its first cycle.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
ARM_SELF="$SCRIPT_DIR/fm-watch-arm.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# Present for exactly as long as THIS arm process is alive; the guards read it to
# tell a normal watcher handoff apart from a genuinely blind turn.
ARMING="$STATE/.watch.arming"
# Why each watcher was replaced, so a churn storm is diagnosable after the fact
# instead of leaving only a silent exit behind.
ARM_LOG="$STATE/.watch-arm.log"
ARM_LOG_MAX=${FM_ARM_LOG_MAX:-200}
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
ARMING_GRACE=${FM_ARMING_GRACE:-30}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}
# Churn budget: how many quiet watcher deaths to absorb inside one window before
# giving up loudly, and how far the relaunch backoff may grow.
RELAUNCH_MAX=${FM_ARM_RELAUNCH_MAX:-8}
CHURN_WINDOW=${FM_ARM_CHURN_WINDOW:-600}
BACKOFF_MAX=${FM_ARM_BACKOFF_MAX:-30}

# --- the arming marker -------------------------------------------------------
# Records this arm's identity so fm_arm_in_flight can verify a REAL live arm
# rather than guess from the marker's mtime: this process now lives across
# watcher restarts, so freshness alone would misread a working arm as dead.
write_arming_marker() {
  local identity
  identity=$(fm_pid_identity "$$" 2>/dev/null || true)
  {
    printf 'pid=%s\n' "$$"
    printf 'identity=%s\n' "$identity"
    printf 'arm-path=%s\n' "$ARM_SELF"
    printf 'fm-home=%s\n' "$FM_HOME"
  } > "$ARMING" 2>/dev/null || true
}

# Keep the mtime fallback fresh too, so an older guard (or one reading a marker
# whose pid it cannot identify) still sees an in-flight re-arm.
touch_arming_marker() {
  touch "$ARMING" 2>/dev/null || true
}

arm_log() {  # <message>
  local stamp lines
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  printf '%s\tpid=%s\t%s\n' "$stamp" "$$" "$1" >> "$ARM_LOG" 2>/dev/null || return 0
  lines=$(wc -l < "$ARM_LOG" 2>/dev/null || echo 0)
  case "$lines" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$lines" -gt $((ARM_LOG_MAX * 2)) ] || return 0
  tail -n "$ARM_LOG_MAX" "$ARM_LOG" > "$ARM_LOG.trim" 2>/dev/null \
    && mv "$ARM_LOG.trim" "$ARM_LOG" 2>/dev/null || rm -f "$ARM_LOG.trim" 2>/dev/null || true
}

clear_stale_recorded_watcher_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$WATCH" ] || return 0
  [ -n "$lock_identity" ] || return 0
  fm_lock_remove_path "$WATCH_LOCK" || true
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
healthy_watcher() {
  HEALTHY_PID=
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" || return 1
  HEALTHY_PID=$FM_WATCHER_HEALTHY_PID
}

report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: attached pid=$HEALTHY_PID (beacon ${age}s)"
}

report_healthy() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: healthy pid=$HEALTHY_PID (beacon ${age}s)"
}

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

# The dead watcher's own first words, if it left any, parenthesized for a churn
# log line. Empty output stays empty rather than printing "()".
first_output_line() {
  local out=$1 line
  line=$(head -n 1 "$out" 2>/dev/null || true)
  [ -n "$line" ] || return 0
  printf ' (%s)' "$line"
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

# Undrained wake records are information firstmate must act on even when the
# watcher that enqueued them died without an arm left to propagate its reason
# line - the exact way a wake used to be lost.
queued_wakes() {
  [ -s "$FM_WAKE_QUEUE" ] || return 1
  wc -l < "$FM_WAKE_QUEUE" 2>/dev/null | tr -d ' '
}

# Sleep in short steps, keeping the arming marker fresh, so a backoff window
# never renders as a blind turn on a guard that reads the marker's mtime.
sleep_holding_marker() {  # <seconds>
  local secs=$1 i=0
  while [ "$i" -lt "$secs" ]; do
    sleep 1
    touch_arming_marker
    i=$((i + 1))
  done
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 2 ;;
esac

# --- one arm per home --------------------------------------------------------
# Stand down for a genuinely live arm instead of attaching to its watcher. Two
# arms on one cycle means two harness notifications per wake, and firstmate
# answers each with another arm: that is how a single quiet wake compounded into
# ~80 live background tasks and a 3-second notification loop. Only a
# pid-VERIFIED live arm stands us down; a stale or unverifiable marker does not.
if [ "$mode" = arm ] \
  && fm_arm_in_flight "$STATE" "$ARM_SELF" "$ARMING_GRACE" "$FM_HOME" \
  && [ -n "$FM_ARM_IN_FLIGHT_PID" ]; then
  if healthy_watcher; then
    echo "watcher: already armed pid=$FM_ARM_IN_FLIGHT_PID (watcher pid=$HEALTHY_PID, beacon $(fm_path_age "$BEAT")s)"
  else
    echo "watcher: already armed pid=$FM_ARM_IN_FLIGHT_PID (restoring its watcher)"
  fi
  exit 0
fi

# Identify this home's incumbent arm BEFORE claiming the marker, because claiming it
# overwrites the only record of who that arm is - and a restart that cannot name the
# incumbent silently leaves it running.
incumbent_arm=
if [ "$mode" = restart ] \
  && fm_arm_in_flight "$STATE" "$ARM_SELF" "$ARMING_GRACE" "$FM_HOME" \
  && [ -n "$FM_ARM_IN_FLIGHT_PID" ] && [ "$FM_ARM_IN_FLIGHT_PID" != "$$" ]; then
  incumbent_arm=$FM_ARM_IN_FLIGHT_PID
fi

# We own supervision from here: take the marker and clear it on every exit path,
# so a completed or killed arm never masks a real supervision gap.
write_arming_marker
trap 'rm -f "$ARMING" 2>/dev/null || true' EXIT

if [ "$mode" = restart ]; then
  # Home-scoped stop of this home's supervision, arm first: a surviving arm would
  # simply relaunch the watcher we are about to stop, leaving two live cycles.
  if [ -n "$incumbent_arm" ]; then
    kill -TERM "$incumbent_arm" 2>/dev/null || true
    i=0
    while [ "$i" -lt 50 ] && fm_pid_alive "$incumbent_arm"; do
      sleep 0.1
      i=$((i + 1))
    done
    # That arm's EXIT trap removed the marker it no longer owns; we hold it now.
    write_arming_marker
  fi
  # Only the watcher pid recorded in THIS home's lock.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$lock_pid" "$FM_HOME"; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      # Wait for it to actually exit before relaunching, so the fresh watcher
      # either takes a released lock or reclaims a now-dead-pid stale lock instead
      # of seeing the dying one as a live holder and no-opping.
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
    else
      clear_stale_recorded_watcher_lock
    fi
  fi
fi

child=
child_out=
cleanup_child() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
}
trap 'cleanup_child; exit 129' HUP
trap 'cleanup_child; exit 143' TERM INT

reap_child() {
  if [ -n "$child" ]; then
    wait "$child" 2>/dev/null || true
  fi
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
  child=
  child_out=
}

# Stay alive until the adopted identity-matched healthy holder is gone.
# If a different healthy watcher appears mid-attach (rare steal), re-attach.
attach_and_wait() {  # <attached-pid>
  local attached_pid=$1
  while :; do
    healthy_watcher || return 0
    if [ "$HEALTHY_PID" != "$attached_pid" ]; then
      attached_pid=$HEALTHY_PID
      report_attached
    fi
    sleep "$ATTACH_POLL"
    touch_arming_marker
  done
}

# Run one supervision cycle: hold exactly one live watcher up and block until it
# ends. Sets CYCLE to what firstmate must be told:
#   wake      - the watcher printed a reason line (already in $child_out)
#   standdown - restart mode found a healthy peer and stood down
#   quiet     - the cycle ended with nothing to report
#   failed    - no watcher could be confirmed (FAILED line already printed)
CYCLE=
CYCLE_DETAIL=
run_cycle() {  # <cycle-mode>
  local cycle_mode=$1 child_done=0 rc deadline detail
  CYCLE=
  CYCLE_DETAIL=

  # A genuinely live+fresh watcher already holds the lock: adopt that cycle
  # rather than start a second one. (--restart skips this on its first cycle: it
  # just stopped this home's supervision and wants a fresh watcher.)
  if [ "$cycle_mode" = arm ] && healthy_watcher; then
    report_attached
    attach_and_wait "$HEALTHY_PID"
    CYCLE=quiet
    CYCLE_DETAIL='adopted watcher ended'
    return 0
  fi

  child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
    echo "watcher: FAILED - no live watcher with a fresh beacon"
    CYCLE=failed
    CYCLE_DETAIL='could not create the watcher output file'
    return 0
  }
  # Capture stderr too: a watcher that refuses to start says so on stderr, and
  # that reason belongs in the churn log and in the eventual FAILED line instead
  # of being discarded into a silent, unexplained exit.
  "$WATCH" >"$child_out" 2>&1 &
  child=$!

  # Verify the outcome: poll until this child is the confirmed healthy watcher, or
  # until some other watcher legitimately holds the singleton (a startup race), or
  # until the child gives up. Only then print the honest line.
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
  while :; do
    if healthy_watcher; then
      if [ "$HEALTHY_PID" = "$child" ]; then
        echo "watcher: started pid=$child (beacon fresh)"
        wait "$child"
        rc=$?
        if watch_output_has_wake "$child_out"; then
          print_watch_output "$child_out"
          CYCLE=wake
        else
          CYCLE=quiet
          CYCLE_DETAIL="watcher pid=$child exited rc=$rc with no wake reason$(first_output_line "$child_out")"
        fi
        rm -f "$child_out" 2>/dev/null || true
        child=
        child_out=
        return 0
      fi
      # Another watcher won the singleton; our child stood down.
      if [ "$cycle_mode" = arm ]; then
        report_attached
        reap_child
        attach_and_wait "$HEALTHY_PID"
        CYCLE=quiet
        CYCLE_DETAIL='adopted peer watcher ended'
        return 0
      fi
      report_healthy
      reap_child
      CYCLE=standdown
      return 0
    fi
    if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
      wait "$child"
      rc=$?
      child_done=1
      if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
        print_watch_output "$child_out"
        rm -f "$child_out" 2>/dev/null || true
        child=
        child_out=
        CYCLE=wake
        return 0
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      # Carry the watcher's own first words into the alarm. A watcher that refuses
      # to start says WHY on stderr ("lock held by live pid ...", "refusing foreign
      # home lock ..."), and dropping it leaves firstmate an alarm it has to go
      # reproduce before it can act on it.
      detail="no live watcher with a fresh beacon$(first_output_line "$child_out")"
      echo "watcher: FAILED - $detail"
      cleanup_child
      wait "$child" 2>/dev/null || true
      child=
      child_out=
      CYCLE=failed
      CYCLE_DETAIL=$detail
      return 0
    fi
    sleep 0.2
    touch_arming_marker
  done
}

# --- supervise ---------------------------------------------------------------
# Exit only on information. Everything else is absorbed here, in this process,
# where it costs nothing.
cycle_mode=$mode
quiet_exits=0
window_start=$(date +%s)
backoff=1
while :; do
  run_cycle "$cycle_mode"
  cycle_mode=arm
  case "$CYCLE" in
    wake)
      arm_log 'exit: watcher wake reason propagated'
      exit 0
      ;;
    standdown)
      arm_log 'exit: restart-only, healthy peer holds the lock'
      exit 0
      ;;
    failed)
      arm_log "exit: FAILED - $CYCLE_DETAIL"
      trap - HUP TERM INT
      exit 1
      ;;
  esac

  # Quiet cycle: the watcher is gone and left nothing to say. Anything it did
  # enqueue is still information, so hand that to firstmate; otherwise replace
  # the watcher in place instead of spending a turn saying nothing.
  if pending=$(queued_wakes); then
    echo "watcher: wakes queued ($pending) - drain them"
    arm_log "exit: $pending queued wake record(s) after $CYCLE_DETAIL"
    exit 0
  fi

  now=$(date +%s)
  if [ $((now - window_start)) -ge "$CHURN_WINDOW" ]; then
    window_start=$now
    quiet_exits=0
    backoff=1
  fi
  quiet_exits=$((quiet_exits + 1))
  arm_log "quiet=$quiet_exits backoff=${backoff}s $CYCLE_DETAIL"
  if [ "$quiet_exits" -gt "$RELAUNCH_MAX" ]; then
    echo "watcher: FAILED - watcher will not stay up ($quiet_exits quiet exits in $((now - window_start))s, last: $CYCLE_DETAIL); see state/.watch-arm.log"
    arm_log 'exit: FAILED - churn budget exhausted'
    trap - HUP TERM INT
    exit 1
  fi
  sleep_holding_marker "$backoff"
  backoff=$((backoff * 2))
  [ "$backoff" -le "$BACKOFF_MAX" ] || backoff=$BACKOFF_MAX
  echo "watcher: relaunching after $quiet_exits quiet exit(s)"
done
