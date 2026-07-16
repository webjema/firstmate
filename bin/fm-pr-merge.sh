#!/usr/bin/env bash
# Merge a task's PR, always recording pr= and any available pr_head= into
# state/<id>.meta first via bin/fm-pr-check.sh, so bin/fm-teardown.sh's
# landed-check has a PR reference to verify a squash merge against.
#
# Why this exists: the normal trigger for running fm-pr-check.sh is the crew's
# `done: PR <url>` line at PR-ready. A merge performed by hand-running
# `gh pr merge` - the common shape of a yolo-authorized merge, especially on a
# repo with no PR CI at all - can skip the recording step entirely. Teardown then
# has nothing to look up for a squash-merge-then-delete-branch flow and
# false-refuses provably landed work.
# This script makes recording part of the merge itself, so it cannot be skipped
# by omission. Use it for every PR merge (user-requested or yolo-authorized),
# in place of calling `gh pr merge` directly.
#
# The merge is a mutation, so it runs on plain gh, never the gh-axi read wrapper.
# The PR URL is parsed to a number plus --repo <owner>/<repo> before anything is
# recorded: the strict parse rejects malformed or unsafe URLs up front, and
# pinning --repo from the URL keeps extra args from redirecting the merge.
#
# Merge method: defaults to --squash when the caller passes none of --squash,
# --merge, or --rebase after the optional -- separator. An explicit
# caller method is never overridden.
# Extra args go verbatim to gh pr merge, so they must be flags gh accepts:
# --method[=x] (a wrapper-ism gh has no flag for) is rejected up front, as are
# --repo and -R because the repo is parsed from the PR URL.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh pr merge args>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh pr merge args>]}
shift 2
[ "${1:-}" = "--" ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2; exit 1; }

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase) return 0 ;;
    esac
  done
  return 1
}

reject_method_flags() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --method|--method=*)
        echo "error: gh pr merge takes --squash, --merge, or --rebase, not --method (got: $arg)" >&2
        return 1
        ;;
    esac
  done
  return 0
}

parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    PR_OWNER="${BASH_REMATCH[1]}"
    PR_REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
    if [[ "$PR_OWNER" != *- ]]; then
      return 0
    fi
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge args must not override --repo parsed from PR URL (got: $arg)" >&2
        return 1
        ;;
    esac
  done
  return 0
}

parse_pr_url "$URL" || exit 1
reject_repo_overrides "$@" || exit 1
reject_method_flags "$@" || exit 1

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ${merge_args[@]+"${merge_args[@]}"} "$@"
