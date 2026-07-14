#!/usr/bin/env bash
# Tests for bin/fm-provision-lib.sh - the wait that replaced fm-spawn.sh's fixed
# 60s "treehouse get did not enter a worktree within 60s" cliff.
#
# The bug: a COLD treehouse slot runs the post_create dependency install before it
# hands over, measured at 137s for optiroq on this box (warm slot: 2s). The old
# poll gave up at 60s, so the first spawn on a fresh box / new project / exhausted
# pool died - and the one error string named none of those causes.
#
# These drive the REAL loop with a scripted pane by overriding the four probes, so
# no tmux, no treehouse, and no multi-GB install is needed. Cases:
#   (a) a cold install that outruns the OLD 60s bound still succeeds  (the fix)
#   (b) a pool-exhausted failure is named as such, and fails FAST      (not at a timeout)
#   (c) a treehouse error relays treehouse's own words, and fails FAST
#   (d) a silent-but-busy pane is caught as STALLED, not "warming"
#   (e) a still-progressing pane hits the ceiling as a WARMING timeout
#   (f) a warm slot returns its path immediately
#   (g) the three failure kinds produce three DIFFERENT messages (no opaque string)
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-provision-lib.sh disable=SC1091
. "$ROOT/bin/fm-provision-lib.sh"

PROJ=/proj

# --- scripted pane ----------------------------------------------------------
# TICK counts loop iterations. Each case sets ENTER_AT (the tick the cwd moves),
# EXIT_AT (the tick the pane's processes vanish), and whether output/pids churn.

TICK=0
ENTER_AT=0
EXIT_AT=0
TAIL=""
CHURN=1

fm_provision_sleep() { TICK=$((TICK + 1)); }

fm_provision_probe_path() {
  if [ "$ENTER_AT" -gt 0 ] && [ "$TICK" -ge "$ENTER_AT" ]; then
    printf '/worktree\n'
  else
    printf '%s\n' "$PROJ"
  fi
}

# A pane is "busy" iff its shell has descendants. An idle shell has none: that is
# how a FAILED treehouse (exited, back at a prompt) is told from a working one.
# PANE_PID='' models a pane whose pid cannot be read at all => state unknown.
#
# BUSY_AT matters more than it looks. This stub USED to report the pane busy from
# TICK=0, and that lie is exactly why the suite stayed green while the code failed
# every real spawn: in reality the pane's shell has not even consumed the keystroke
# on the first probe (measured 10/10 idle), so it starts IDLE and only goes busy a
# tick later. BUSY_AT defaults to 1 to model that. Never set it to 0 "to keep the
# tests simple" - that is the bug, re-asserted.
PANE_PID=4242
BUSY_AT=1
fm_provision_probe_pane_pid() { printf '%s' "$PANE_PID"; }

fm_provision_probe_descendants() {
  if [ "$TICK" -lt "$BUSY_AT" ]; then
    return 0  # the shell has not picked up the command yet: no children
  fi
  if [ "$EXIT_AT" -gt 0 ] && [ "$TICK" -ge "$EXIT_AT" ]; then
    return 0  # no descendants: treehouse exited
  fi
  printf '%s\n' 1000
  [ "$CHURN" -eq 1 ] && printf '%s\n' "$((2000 + TICK))"  # npm churning children
  return 0
}

fm_provision_probe_tail() { printf '%s\n' "$TAIL"; }

# fm_provision_real_path must not touch the filesystem for these synthetic paths.
fm_provision_real_path() { printf '%s' "$1"; }

reset_pane() { TICK=0; ENTER_AT=0; EXIT_AT=0; TAIL=""; CHURN=1; PANE_PID=4242; BUSY_AT=1; }

# run_wait <timeout> <stall>: drive the loop IN THIS SHELL (never a command
# substitution - a subshell would discard the pane script's TICK) and capture its
# streams. Sets OUT, ERR and RC.
TMP_ROOT=$(fm_test_tmproot fm-provision)
mkdir -p "$TMP_ROOT"
run_wait() {
  local rc=0
  fm_provision_wait pane "$PROJ" "$1" "$2" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || rc=$?
  OUT=$(cat "$TMP_ROOT/out")
  ERR=$(cat "$TMP_ROOT/err")
  RC=$rc
}

# --- (a) the fix: a cold install far past the old 60s cliff still succeeds ----
reset_pane
ENTER_AT=137          # the measured cold-install duration, in ticks
TAIL='[treehouse post_create] installing deps ...'
run_wait 900 300
[ "$RC" -eq 0 ] || fail "(a) cold install must be waited out, not killed: $ERR"
[ "$OUT" = /worktree ] || fail "(a) expected the worktree path, got '$OUT'"
[ "$TICK" -ge 61 ] || fail "(a) test bug: must outrun the old 60s bound (ticks=$TICK)"
pass "(a) a 137s cold install - which the old 60s poll killed - now succeeds"

# --- (b) pool exhausted: named, and fast ------------------------------------
reset_pane
EXIT_AT=3
TAIL='error: all 16 worktrees are in use or dirty (max_trees = 16). Run treehouse status to see details'
run_wait 900 300
[ "$RC" -ne 0 ] || fail "(b) an exhausted pool must fail"
assert_contains "$ERR" "pool is FULL" "(b) must name pool exhaustion"
assert_contains "$ERR" "max_trees" "(b) must carry treehouse's own reason"
assert_contains "$ERR" "prune" "(b) must say a dirty slot is never auto-reclaimed"
[ "$TICK" -le 10 ] || fail "(b) must fail FAST, not at a timeout (ticks=$TICK)"
pass "(b) a full pool is reported as exhausted, in seconds - not as a timeout"

# --- (c) treehouse errored: its own words are relayed, fast ------------------
reset_pane
EXIT_AT=2
TAIL='fatal: could not read from remote repository'
run_wait 900 300
[ "$RC" -ne 0 ] || fail "(c) a treehouse error must fail"
assert_contains "$ERR" "treehouse get FAILED" "(c) must name a treehouse failure"
assert_contains "$ERR" "could not read from remote repository" "(c) must relay treehouse's words"
[ "$TICK" -le 10 ] || fail "(c) must fail FAST (ticks=$TICK)"
pass "(c) a treehouse error relays treehouse's own message and fails fast"

# --- (d) busy but silent: STALLED, not mistaken for warming ------------------
reset_pane
CHURN=0                       # a wedged process: alive, but nothing moves
TAIL='waiting for input...'
run_wait 900 30
[ "$RC" -ne 0 ] || fail "(d) a wedged pane must fail"
assert_contains "$ERR" "STUCK" "(d) must name it stuck, not warming"
assert_not_contains "$ERR" "WARMING" "(d) a wedge is not a cold install"
pass "(d) a busy-but-dead-silent pane is caught as stuck, never waited out forever"

# --- (e) still progressing at the ceiling: a WARMING timeout -----------------
reset_pane
TAIL='[worktree-setup] npm install packages/optiroq-domain'
run_wait 20 300
[ "$RC" -ne 0 ] || fail "(e) the ceiling must still bound the wait"
assert_contains "$ERR" "WARMING A COLD WORKSPACE" "(e) must say what it was doing"
assert_contains "$ERR" "FM_SPAWN_WORKTREE_TIMEOUT" "(e) must name the knob to raise"
pass "(e) a still-warming pane at the ceiling says so, and names the knob"

# --- (f) a warm slot is handed over immediately ------------------------------
reset_pane
ENTER_AT=1
run_wait 900 300
[ "$RC" -eq 0 ] || fail "(f) a warm slot must succeed: $ERR"
[ "$OUT" = /worktree ] || fail "(f) expected the worktree path, got '$OUT'"
[ "$TICK" -le 2 ] || fail "(f) a warm slot must not be slow (ticks=$TICK)"
pass "(f) a warm slot is handed over immediately"

# --- (h) an UNREADABLE pane pid must never be read as "exited" ---------------
# A backend whose pane pid cannot be read (an incomplete adapter, a tmux hiccup)
# reports neither busy nor idle. Treating that unknown as idle would kill a spawn
# whose install is running perfectly well - the same false-dead trap
# fm_backend_agent_alive guards against. It must keep waiting instead.
reset_pane
PANE_PID=""           # unreadable
ENTER_AT=3            # the pane WAS fine, and enters the worktree shortly after
TAIL=""
run_wait 900 300
[ "$RC" -eq 0 ] || fail "(h) an unreadable pane pid must not be treated as a dead pane: $ERR"
[ "$OUT" = /worktree ] || fail "(h) expected the worktree path, got '$OUT'"
pass "(h) an unreadable pane state keeps waiting - unknown is never a dead pane"

# --- (j) an idle pane at tick 0 is the SHELL STARTING, not a failure ----------
# The B1 regression, at unit level (tests/fm-provision-pane-e2e.test.sh holds the
# same line against a real pane). The pane reads idle for the first ticks because
# the shell has not consumed the keystroke yet; believing that killed every spawn.
reset_pane
BUSY_AT=3             # the shell takes a few probes to pick the command up
ENTER_AT=8
run_wait 900 300
[ "$RC" -eq 0 ] || fail "(j) an idle pane that has not started yet must NOT be called a failure: $ERR"
[ "$OUT" = /worktree ] || fail "(j) expected the worktree path, got '$OUT'"
pass "(j) an idle pane at tick 0 is a shell still starting, not treehouse giving up"

# --- (i) the quoted line is the ERROR, not the shell prompt -------------------
# Found by driving a real tmux pane: by the time a failed `treehouse get` is
# noticed, the pane has returned to its prompt, so the LAST non-empty line is the
# prompt itself - and quoting it told the operator nothing. Quote the complaint.
reset_pane
EXIT_AT=2
TAIL='error: all 16 worktrees are in use or dirty (max_trees = 16)
user@box:~/projects/optiroq$ '
run_wait 900 300
[ "$RC" -ne 0 ] || fail "(i) an exhausted pool must fail"
assert_contains "$ERR" "all 16 worktrees are in use or dirty" "(i) must quote treehouse's actual error"
assert_not_contains "$ERR" "user@box" "(i) must NOT quote the shell prompt back at the operator"
pass "(i) the failure quotes treehouse's error line, not the shell prompt beneath it"

# --- (g) three causes, three DIFFERENT messages ------------------------------
# The whole point of the change: one opaque string used to cover all of these.
m_pool=$(fm_provision_failure pool-exhausted 'max_trees = 16')
m_err=$(fm_provision_failure treehouse-error 'fatal: boom')
m_time=$(fm_provision_failure timeout 'npm install' 900)
[ "$m_pool" != "$m_err" ] && [ "$m_err" != "$m_time" ] && [ "$m_pool" != "$m_time" ] \
  || fail "(g) the three failure causes must not share one message"
[ "$(fm_provision_classify_tail 'all 16 worktrees are in use or dirty (max_trees = 16)')" = pool-exhausted ] \
  || fail "(g) treehouse's exhaustion wording must classify as pool-exhausted"
[ "$(fm_provision_classify_tail 'fatal: no such repo')" = treehouse-error ] \
  || fail "(g) an error tail must classify as treehouse-error"
[ "$(fm_provision_classify_tail '')" = no-worktree ] \
  || fail "(g) a silent exit must classify as no-worktree"
pass "(g) pool-exhausted, treehouse-error and timeout are three distinct messages"
