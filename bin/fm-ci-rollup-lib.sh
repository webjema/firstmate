# shellcheck shell=bash
# Single owner of firstmate's PR CI-rollup verdict: the one definition of "is this
# PR green, red, or still running" shared by the two places that need it -
# bin/fm-pr-check.sh (the watcher's merge/CI poll) and bin/fm-pr-merge.sh (the
# never-merge-a-red-PR gate).
# Usage: . bin/fm-ci-rollup-lib.sh
#
# FM_CI_ROLLUP_QUERY is a gh jq-syntax `-q` expression, so a caller needs no
# external jq and makes exactly one API call. It reduces a PR to a single line
# "<state> <headRefOid> <verdict>" where verdict is one of:
#   fail    - any terminal red/blocked check conclusion
#   pending - anything still queued, running, or awaiting a status context
#   pass    - every check completed and none red
#   none    - the repo reports no checks on this PR
# Each rollup entry is either a CheckRun (status QUEUED/IN_PROGRESS/COMPLETED plus a
# conclusion) or a StatusContext (state), so each is normalized to f=<conclusion|state>
# and s=<status> before the verdict. CANCELLED/SKIPPED/NEUTRAL are deliberately NOT
# failures: a cancelled superseded run is routine concurrency, and treating it as red
# would be a false alarm (a false wake for the poll, a false refusal for the gate).
FM_CI_ROLLUP_QUERY='
  [ .state,
    (.headRefOid // "none"),
    ( (.statusCheckRollup // [])
      | map({ f: (.conclusion // .state // ""), s: (.status // "") })
      | if length == 0 then "none"
        elif any(.[]; .f == "FAILURE" or .f == "TIMED_OUT" or .f == "ACTION_REQUIRED" or .f == "STARTUP_FAILURE" or .f == "ERROR") then "fail"
        elif any(.[]; (.s != "" and .s != "COMPLETED") or .f == "PENDING" or .f == "EXPECTED" or .f == "") then "pending"
        else "pass" end )
  ] | join(" ")'

# fm_ci_rollup_line <pr-url>: echo "<state> <headRefOid> <verdict>" for the PR, or
# nothing on any tool error (gh missing, unauthenticated, or the call fails). A
# caller treats an empty result as "cannot determine" and must not act on it as red,
# exactly as the poll never wakes on a tool error.
fm_ci_rollup_line() {
  local url=$1
  command -v gh >/dev/null 2>&1 || return 0
  gh pr view "$url" --json state,headRefOid,statusCheckRollup -q "$FM_CI_ROLLUP_QUERY" 2>/dev/null || return 0
}
