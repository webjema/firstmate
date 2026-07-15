#!/usr/bin/env bash
# The ONE authoritative, agent-callable answer to "is a live watcher supervising
# THIS home?".
#
# Firstmate calls this directly instead of improvising a check (a process grep, a
# beacon-freshness read, or a payload-less invocation of the turn-end hook - all
# three gave confident WRONG answers). The verdict is home-lock OWNERSHIP via
# bin/fm-wake-lib.sh's fm_watcher_healthy, the SAME predicate bin/fm-guard.sh and
# bin/fm-turnend-guard.sh use, so this can never disagree with them. A fresh
# beacon over no lock (an orphaned watcher supervising nothing) reads as DOWN
# here, because ownership of the home lock - not beacon freshness - is the truth.
#
# Unlike the turn-end guard, this needs no hook payload: invoked directly it still
# answers honestly. It reports what this home is supervising and how, so it
# extends cleanly to future supervision classes (e.g. a custody-only detached
# task with no per-wake watcher) without hard-assuming every recorded task demands
# a live watcher - it answers strictly about the watcher, and prints the in-flight
# count as context.
#
# Output: one line on stdout.
#   watcher: live pid=<N> (holds this home lock, beacon <age>s) - <k> task(s) in flight
#   watcher: DOWN - no live watcher holds this home lock (beacon <desc>) - <k> task(s) in flight
# Exit: 0 when live, 1 when DOWN. --quiet suppresses the line (exit code only).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
BEAT="$STATE/.last-watcher-beat"

QUIET=0
case "${1:-}" in
  ''|--) ;;
  --quiet) QUIET=1 ;;
  -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: $(basename "$0") [--quiet]" >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

fm_supervision_status "$STATE" "$GRACE"

if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  [ "$QUIET" -eq 1 ] || printf 'watcher: live pid=%s (holds this home lock, beacon %ss) - %s task(s) in flight\n' \
    "$FM_WATCHER_HEALTHY_PID" "$(fm_path_age "$BEAT")" "$FM_SUP_IN_FLIGHT"
  exit 0
fi

[ "$QUIET" -eq 1 ] || printf 'watcher: DOWN - no live watcher holds this home lock (beacon %s) - %s task(s) in flight\n' \
  "$FM_SUP_BEACON_DESC" "$FM_SUP_IN_FLIGHT"
exit 1
