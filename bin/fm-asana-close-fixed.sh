#!/usr/bin/env bash
# Close the product-board cards a merged PR says it fixes.
#
# A PR body names a card it fixes with a line that starts with a fix verb, optionally after a
# "- " or "* " bullet, before the card's gid or URL: "Fixes 1220085825742004", "Closes: asana
# 1220085825742004", "Resolves https://app.asana.com/0/<project>/<gid>" or the
# https://app.asana.com/1/<ws>/project/<project>/task/<gid> form. The verbs are fix, fixes,
# fixed, close, closes, closed, resolve, resolves and resolved, in any case. A verb inside a
# sentence ("does not fix 1220...") closes nothing. A bare "Asana: <gid>" only links the card
# and closes nothing, because a PR often touches a card it does not finish.
#
# For each named card on a board config/product-tracker names (bin/fm-file-finding.sh's
# header owns that contract), this comments "Fixed by <pr-url>" and completes the card. A
# card that is already completed, or that is on no configured board, is left alone. The PR
# must be MERGED; an open or closed-unmerged PR closes nothing.
#
# It is best effort and idempotent: bin/fm-pr-merge.sh runs it after its merge, and the
# state/<id>.check.sh poll bin/fm-pr-check.sh arms runs it when it sees the merge, so a PR
# merged by hand or by a pipeline is caught too. Running it twice completes nothing twice.
#
# Prints one line per card it closed or skipped.
# Exit status: 0 on success, including nothing to close; 2 for a usage error; 1 when gh or
# an Asana call failed.
# Usage: fm-asana-close-fixed.sh <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

URL=${1:-}
case "$URL" in
  -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
  '') echo "usage: fm-asana-close-fixed.sh <pr-url>" >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "fm-asana-close-fixed.sh: jq is required" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-asana-close.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=bin/fm-asana-lib.sh
. "$SCRIPT_DIR/fm-asana-lib.sh"

[ -n "$DEFAULT_PROJECT$TRACKER_MAP" ] || exit 0
asana_ready || { echo "fm-asana-close-fixed.sh: $API_ERR" >&2; exit 1; }

pr=$(gh pr view "$URL" --json state,body 2>/dev/null) ||
  { echo "fm-asana-close-fixed.sh: could not read $URL" >&2; exit 1; }
[ "$(printf '%s' "$pr" | jq -r '.state')" = MERGED ] || exit 0

gids=$(printf '%s' "$pr" | jq -r '.body // ""' |
  grep -oiE '^[[:space:]>]*([-*][[:space:]]+)?(fix(es|ed)?|close[sd]?|resolve[sd]?)[[:space:]:]+(asana[[:space:]:]+)?(task[[:space:]:]+)?(https://app\.asana\.com/(0/[0-9]+/|1/[0-9]+/(project/[0-9]+/)?task/))?[0-9]{13,19}([^0-9]|$)' |
  sed -E 's/[^0-9]*$//; s/.*[^0-9]//' | sort -u) || true
[ -n "$gids" ] || exit 0

boards=$(tracker_boards)
rc=0
for gid in $gids; do
  if ! asana_api GET "/tasks/$gid?opt_fields=completed,memberships.project.gid"; then
    echo "fm-asana-close-fixed.sh: could not read card $gid ($API_ERR)" >&2
    rc=1
    continue
  fi
  if [ "$(printf '%s' "$API_BODY" | jq -r '.data.completed // false')" = true ]; then
    echo "skipped: $gid already completed"
    continue
  fi
  if ! printf '%s' "$API_BODY" | jq -r '.data.memberships[]?.project.gid // empty' | grep -qxF -f <(printf '%s\n' "$boards"); then
    echo "skipped: $gid is on no configured board"
    continue
  fi
  if asana_comment "$gid" "Fixed by $URL" && asana_complete "$gid"; then
    echo "closed: $gid fixed by $URL"
  else
    echo "fm-asana-close-fixed.sh: could not close card $gid ($API_ERR)" >&2
    rc=1
  fi
done
exit "$rc"
