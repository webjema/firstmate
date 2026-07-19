#!/usr/bin/env bash
# Tests for bin/fm-recovery-ledger.sh: the mechanical hard cap on a mission's
# autonomous recovery-adjudication rung, so the loop cannot churn forever before it
# escalates to the captain.
#
# The load-bearing behaviors:
#   (a) count starts at 0 and rises with each retry/replan attempt
#   (b) escalate is terminal and never counts against the cap
#   (c) tripped reports TRIP/exit-0 at or past the cap and OK/exit-1 below it, with a
#       per-call --cap override and an FM_RECOVERY_CAP default
#   (d) a bad action is rejected, and reset clears the ledger
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER="$ROOT/bin/fm-recovery-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-recovery-ledger-tests)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

run_ledger() {
  local home=$1; shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$LEDGER" "$@"
}

# (a) ------------------------------------------------------------------------
test_count_starts_zero_and_rises() {
  local home
  home=$(make_home rises)
  [ "$(run_ledger "$home" count t1)" = 0 ] || fail "count: an empty ledger must be 0"
  [ "$(run_ledger "$home" record t1 retry)" = 1 ] || fail "record: first retry -> 1"
  [ "$(run_ledger "$home" record t1 replan)" = 2 ] || fail "record: replan -> 2"
  [ "$(run_ledger "$home" count t1)" = 2 ] || fail "count: must reflect recorded attempts"
  pass "count starts at zero and rises with each retry/replan"
}

# (b) ------------------------------------------------------------------------
test_escalate_is_terminal_and_uncounted() {
  local home
  home=$(make_home escalate)
  run_ledger "$home" record t1 retry >/dev/null
  [ "$(run_ledger "$home" record t1 escalate)" = 1 ] || fail "record: escalate must not increment the count"
  [ "$(run_ledger "$home" count t1)" = 1 ] || fail "count: escalate must not count against the cap"
  pass "escalate is terminal and never counts against the cap"
}

# (c) ------------------------------------------------------------------------
test_tripped_at_and_below_cap() {
  local home rc out
  home=$(make_home tripped)

  # Below the default cap of 3: OK, exit 1.
  run_ledger "$home" record t1 retry >/dev/null
  run_ledger "$home" record t1 retry >/dev/null
  rc=0; out=$(run_ledger "$home" tripped t1) || rc=$?
  [ "$out" = OK ] && [ "$rc" -eq 1 ] || fail "tripped: below cap must print OK and exit 1 (got '$out' rc=$rc)"

  # At the cap: TRIP, exit 0.
  run_ledger "$home" record t1 replan >/dev/null
  rc=0; out=$(run_ledger "$home" tripped t1) || rc=$?
  [ "$out" = TRIP ] && [ "$rc" -eq 0 ] || fail "tripped: at cap must print TRIP and exit 0 (got '$out' rc=$rc)"

  # A per-call --cap override lifts the ceiling.
  rc=0; out=$(run_ledger "$home" tripped t1 --cap 5) || rc=$?
  [ "$out" = OK ] && [ "$rc" -eq 1 ] || fail "tripped: --cap override must not trip below the new cap"
  pass "tripped reports TRIP at/past the cap and OK below it, with --cap override"
}

test_tripped_honors_env_cap() {
  local home rc out
  home=$(make_home env_cap)
  run_ledger "$home" record t1 retry >/dev/null
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_RECOVERY_CAP=1 "$LEDGER" tripped t1) || rc=$?
  [ "$out" = TRIP ] && [ "$rc" -eq 0 ] || fail "tripped: FM_RECOVERY_CAP=1 must trip at one attempt (got '$out' rc=$rc)"
  pass "tripped honors the FM_RECOVERY_CAP default"
}

# (d) ------------------------------------------------------------------------
test_bad_action_rejected_and_reset_clears() {
  local home rc
  home=$(make_home bad_reset)
  rc=0; run_ledger "$home" record t1 bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "record: an unknown action must be rejected"

  run_ledger "$home" record t1 retry >/dev/null
  [ "$(run_ledger "$home" count t1)" = 1 ] || fail "count: valid record after a rejected one"
  run_ledger "$home" reset t1 >/dev/null
  [ "$(run_ledger "$home" count t1)" = 0 ] || fail "reset: must clear the ledger back to 0"
  pass "a bad action is rejected and reset clears the ledger"
}

test_count_starts_zero_and_rises
test_escalate_is_terminal_and_uncounted
test_tripped_at_and_below_cap
test_tripped_honors_env_cap
test_bad_action_rejected_and_reset_clears
