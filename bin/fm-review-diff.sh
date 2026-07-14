#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and local-only projects against the local default branch.
# When state/<id>.meta records pr= for an open PR, the compare side is the PR
# head (recorded pr_head= when reachable, else refs/pull/<n>/head), because the
# local worktree branch can lag the PR: the crew's own review-and-fix rounds and
# any CI-fix rounds push commits that need not exist locally. Reviewing the PR
# head is what keeps firstmate's review of the real, mergeable change. If the PR
# head cannot be resolved, the script falls back to the local branch with a warning.
#
# SUMMARY FIRST. The default used to print the stat AND the entire unbounded diff,
# which on a large change is one of the most expensive reads in the supervision loop
# - and most of it is read by nobody. The default is now the map: the base, the
# stat, and a per-file size table. The code itself is one explicit command away, and
# the summary says so LOUDLY: an elided diff that reads as complete is worse than an
# expensive one, so nothing here is ever silently truncated.
#
# Usage: fm-review-diff.sh <task-id> [--full | --files <path>... ]
#   (default)        base + stat + per-file sizes, and how to get the code
#   --full           the above plus the complete diff (the historical default)
#   --files <p>...   the above plus the complete diff for those paths only
#   --stat           accepted as an alias of the default (it is now the default)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-review-diff.sh <task-id> [--full | --files <path>...]" >&2
  echo "       default: base + stat + per-file sizes (no diff body)" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
shift || true
MODE=summary
PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --full)  MODE=full; shift ;;
    --stat)  MODE=summary; shift ;;   # the historical flag; now what the default does
    --files)
      MODE=files
      shift
      [ $# -gt 0 ] || { echo "error: --files needs at least one path" >&2; usage; exit 1; }
      while [ $# -gt 0 ]; do PATHS+=("$1"); shift; done
      ;;
    *) usage; exit 1 ;;
  esac
done

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
[ -n "$WT" ] || { echo "error: meta for task $ID is missing worktree=" >&2; exit 1; }
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

BRANCH="fm/$ID"
if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: branch fm/$ID does not exist and worktree $WT is detached" >&2; exit 1; }
  git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $WT" >&2; exit 1; }
fi

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

resolve_pr_head() {
  local pr_url=$1 recorded_head=$2 n resolved
  if [ -n "$recorded_head" ] \
    && git -C "$WT" cat-file -e "$recorded_head^{commit}" 2>/dev/null; then
    printf '%s' "$recorded_head"
    return 0
  fi
  n=$(pr_number_from_target "$pr_url") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  resolved=$(git -C "$WT" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null) || return 1
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
}

PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
COMPARE_REF=$BRANCH
if [ -n "$PR_URL" ]; then
  if PR_HEAD=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
    COMPARE_REF=$PR_HEAD
  else
    echo "warning: PR head unavailable; diff may lag the open PR (using local branch $BRANCH)" >&2
  fi
fi

if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  # Update the remote-tracking ref itself; a bare single-branch fetch can leave
  # origin/<default> stale on some Git versions and only refresh FETCH_HEAD.
  git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
  BASE="origin/$DEFAULT"
else
  BASE="$DEFAULT"
fi

git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "error: base $BASE does not exist in $WT" >&2; exit 1; }
git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }

echo "diff base: $BASE"
if git -C "$WT" diff --quiet "$BASE...$COMPARE_REF" --; then
  echo "no changes vs $BASE"
  exit 0
fi

git -C "$WT" diff --stat "$BASE...$COMPARE_REF" --

case "$MODE" in
  full)
    echo
    git -C "$WT" diff "$BASE...$COMPARE_REF" --
    ;;
  files)
    echo
    echo "showing ${#PATHS[@]} of $(git -C "$WT" diff --name-only "$BASE...$COMPARE_REF" -- | wc -l | tr -d ' ') changed files"
    git -C "$WT" diff "$BASE...$COMPARE_REF" -- "${PATHS[@]}"
    ;;
  summary)
    # The per-file size table: what a reviewer needs to decide WHICH code to read.
    # Sorted biggest-first, because that is the order the reading decision is made in.
    echo
    echo "per-file sizes (added/removed lines):"
    git -C "$WT" diff --numstat "$BASE...$COMPARE_REF" -- \
      | sort -k1,1nr \
      | while read -r add del path; do
          printf '  +%-6s -%-6s %s\n' "$add" "$del" "$path"
        done
    # Say what was left out, and exactly how to get it. An elided diff that reads as
    # complete is worse than an expensive one.
    echo
    echo "ELIDED: the diff body is not shown above."
    echo "  full diff:      bin/fm-review-diff.sh $ID --full"
    echo "  selected files: bin/fm-review-diff.sh $ID --files <path> [<path>...]"
    ;;
esac
