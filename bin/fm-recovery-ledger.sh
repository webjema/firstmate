#!/usr/bin/env bash
# Record a task's autonomous recovery-adjudication attempts and enforce a hard cap,
# so a mission's recovery rung mechanically cannot loop forever before it escalates
# to the captain. The cap is enforced here, not left to the adjudicating agent's
# awareness: an autonomous loop that policed its own limit is exactly the failure
# this guards against.
#
# Each attempt is one line in state/<id>.recovery (append-only), one of:
#   retry    - relaunched the crew with corrective guidance
#   replan   - abandoned this attempt and re-planned the task
#   escalate - handed the task to the captain (terminal; ends the loop)
# retry and replan are the capped attempts; escalate is the terminal exit and is
# never counted against the cap.
#
# Usage: fm-recovery-ledger.sh record <id> <retry|replan|escalate>
#            append an attempt; print the new capped-attempt count (retry+replan)
#        fm-recovery-ledger.sh count <id>
#            print the capped-attempt count (retry+replan lines)
#        fm-recovery-ledger.sh tripped <id> [--cap <n>]
#            print TRIP and exit 0 when count >= cap; print OK and exit 1 otherwise.
#            The cap defaults to FM_RECOVERY_CAP (default 3).
#        fm-recovery-ledger.sh show <id>     print the ledger, or nothing when absent
#        fm-recovery-ledger.sh reset <id>    clear the ledger (a fresh start)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

DEF_CAP=${FM_RECOVERY_CAP:-3}

die() { echo "error: $*" >&2; exit 1; }

file_for() { printf '%s\n' "$STATE/$1.recovery"; }

# Count the capped attempts: retry and replan lines. escalate is terminal and never
# counts, so a task that escalated does not itself push the count past the cap.
count_attempts() {
  local f=$1 n
  [ -f "$f" ] || { printf '0\n'; return 0; }
  # grep -c prints the count (0 included) and exits 1 when there are no matches, so
  # capture its output and swallow that exit rather than treating 0-matches as error.
  n=$(grep -cxE 'retry|replan' "$f" 2>/dev/null) || true
  printf '%s\n' "${n:-0}"
}

cmd_record() {
  local id=$1 action=$2 f count
  case "$action" in
    retry|replan|escalate) : ;;
    *) die "action must be one of retry, replan, escalate (got '$action')" ;;
  esac
  f=$(file_for "$id")
  mkdir -p "$STATE"
  printf '%s\n' "$action" >> "$f"
  count=$(count_attempts "$f")
  printf '%s\n' "$count"
}

cmd_count() {
  local f
  f=$(file_for "$1")
  count_attempts "$f"
}

cmd_tripped() {
  local id=$1; shift
  local cap=$DEF_CAP
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --cap) cap=${2:?--cap needs a value}; shift 2 ;;
      --*)   die "unknown flag '$1' (see --help)" ;;
      *)     die "unexpected argument '$1'" ;;
    esac
  done
  case "$cap" in
    ''|*[!0-9]*) die "--cap must be a non-negative integer (got '$cap')" ;;
  esac
  local f count
  f=$(file_for "$id")
  count=$(count_attempts "$f")
  if [ "$count" -ge "$cap" ]; then
    echo "TRIP"
    return 0
  fi
  echo "OK"
  return 1
}

cmd_show() {
  local f
  f=$(file_for "$1")
  [ -f "$f" ] || return 0
  cat "$f"
}

cmd_reset() {
  local f
  f=$(file_for "$1")
  rm -f "$f"
  echo "reset: $f"
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac

ACTION=$1
shift || true

case "$ACTION" in
  record)  [ "$#" -ge 2 ] || die "record needs a task id and an action"; cmd_record "$1" "$2" ;;
  count)   [ "$#" -ge 1 ] || die "count needs a task id"; cmd_count "$1" ;;
  tripped) [ "$#" -ge 1 ] || die "tripped needs a task id"; cmd_tripped "$@" ;;
  show)    [ "$#" -ge 1 ] || die "show needs a task id"; cmd_show "$1" ;;
  reset)   [ "$#" -ge 1 ] || die "reset needs a task id"; cmd_reset "$1" ;;
  *)       die "unknown action '$ACTION' (see --help)" ;;
esac
