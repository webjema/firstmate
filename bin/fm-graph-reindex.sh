#!/usr/bin/env bash
# Refresh one project's codebase-memory knowledge graph so the graph describes the
# code that is actually checked out. Called by bin/fm-fleet-sync.sh right after a
# clone fast-forwards - the moment the old graph starts describing code that no
# longer exists - and usable by hand for a one-off refresh.
# Usage: fm-graph-reindex.sh <project-dir-or-name>
# Accepts a path (used as-is when it exists) or a bare "<name>"/"projects/<name>"
# form resolved against this home's projects dir ($FM_HOME/projects, or
# $FM_PROJECTS_OVERRIDE). fm-fleet-sync.sh passes an already-resolved path.
#
# INDEXES ONLY ORIGIN'S DEFAULT-BRANCH TIP. Before indexing a clone that has an
# origin, it runs bin/fm-fleet-sync.sh on it - the one fast-forward path, with its
# never-force rules - and then indexes only when HEAD equals origin/<default>.
# Otherwise it prints "<project>: graph NOT refreshed: ..." on stdout with the
# sync's own reason, and indexes nothing; a tracked change at the tip is refused
# the same way. A clone with no origin, a local-only project, or a plain directory
# is indexed as it stands. FM_GRAPH_SYNC_INNER set means the caller is fm-fleet-sync.sh, which just
# synced, so the sync is skipped and only the HEAD check runs. Callers match the
# exact text "graph refreshed" for success (optiroq-workstation's pipeline
# closeout), so no other line may contain it.
#
# BEST-EFFORT BY CONTRACT, and it exits 0 on every graph outcome so no caller can
# go red because a cache is unavailable. A refresh that succeeds prints one
# "<project>: graph refreshed ..." line on stdout; every skip and every failure
# warns on stderr and is otherwise silent, so a session-start fleet refresh (which
# relays stdout) stays quiet unless something actually happened.
#
# EVERY FAILURE NAMES ITS CAUSE, quoting the CLI's own words. This is not polish:
# for a fortnight a refresh that could never succeed - the CLI had changed its
# argument surface out from under bin/fm-graph-lib.sh - printed only "graph refresh
# failed", and a non-fatal warning nobody can act on is indistinguishable from
# noise. A warning that says what broke is what makes the next such change land in
# minutes rather than a fortnight; docs/graph-cli-backend.md records that incident.
#
# ONLY REFRESHES PROJECTS THE GRAPH ALREADY HOLDS. A project the graph does not
# know is skipped, never indexed: a first index of a large repo is slow, and
# choosing to index a project is a decision, not a side effect of a merge. Index
# it once by hand (or over MCP) and every later merge refreshes it from here.
#
# The graph contract itself - binary resolution, call bounding, output parsing,
# the mode knob, and the never-write-into-a-clone rule - lives in
# bin/fm-graph-lib.sh, which is its single owner.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-graph-lib.sh
. "$SCRIPT_DIR/fm-graph-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

# --help prints this file's whole header, which is the contract's one home.
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ $# -eq 1 ] || { usage >&2; exit 1; }

ARG=$1
DIR=$ARG
case "$ARG" in
  projects/*)
    if [ -d "$PROJECTS/${ARG#projects/}" ]; then DIR="$PROJECTS/${ARG#projects/}"; fi
    ;;
  */*) : ;;
  *)
    if [ -d "$PROJECTS/$ARG" ]; then DIR="$PROJECTS/$ARG"; fi
    ;;
esac
LABEL=$(basename "$DIR")

if [ ! -d "$DIR" ]; then
  echo "$LABEL: graph skipped: not a directory" >&2
  exit 0
fi

MODE=$(fm_graph_mode)
if [ "$MODE" = off ]; then
  echo "$LABEL: graph skipped: refresh disabled (mode=off)" >&2
  exit 0
fi

if ! fm_graph_cli >/dev/null; then
  echo "$LABEL: graph skipped: codebase-memory CLI unavailable" >&2
  exit 0
fi

# The helpers run inside command substitutions, so the cause of a failure comes
# back through this file rather than a variable the subshell would take with it.
# Set up before the first call and read after each one; see fm_graph_note_error.
ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-graph-reindex.XXXXXX") || ERR_FILE=
FM_GRAPH_ERR_FILE="$ERR_FILE"
trap '[ -z "${ERR_FILE:-}" ] || rm -f "$ERR_FILE"' EXIT

# cause: the CLI's own account of the last failure, or a stand-in when it said
# nothing. Always non-empty, so a warning never trails off into a bare colon.
cause() {
  local text=
  [ -z "${ERR_FILE:-}" ] || text=$(cat "$ERR_FILE" 2>/dev/null) || text=
  printf '%s\n' "${text:-no cause reported}"
}

LOOKUP=0
NAME=$(fm_graph_project_for_path "$DIR") || LOOKUP=$?
if [ "$LOOKUP" -eq 2 ]; then
  # Distinct from "not indexed" on purpose: telling someone to index a project
  # they already indexed is what a broken CLI looks like when it is misdiagnosed.
  echo "$LABEL: graph skipped: could not read the graph's project list: $(cause)" >&2
  exit 0
elif [ "$LOOKUP" -ne 0 ]; then
  echo "$LABEL: graph skipped: not found in the graph (index it once to opt in to refreshes)" >&2
  exit 0
fi

# Gated only for a clone of its own (not a plain dir that git resolves to an
# enclosing repo) that tracks an origin and is not a local-only project.
TOP=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || TOP=
GATED=no
if [ -n "$TOP" ] && [ "$TOP" = "$(cd "$DIR" && pwd -P)" ] \
    && git -C "$DIR" remote get-url origin >/dev/null 2>&1; then
  PMODE=$("$FM_ROOT/bin/fm-project-mode.sh" "$LABEL" 2>/dev/null || echo "PR off")
  [ "${PMODE%% *}" = local-only ] || GATED=yes
fi
if [ "$GATED" = yes ]; then
  SYNC_OUT=
  if [ -z "${FM_GRAPH_SYNC_INNER:-}" ]; then
    SYNC_OUT=$(FM_GRAPH_SYNC_INNER=1 "$FM_ROOT/bin/fm-fleet-sync.sh" "$DIR" 2>/dev/null) || true
    [ -z "$SYNC_OUT" ] || printf '%s\n' "$SYNC_OUT" >&2
  fi
  HEAD_REV=$(git -C "$DIR" rev-parse --verify --quiet HEAD 2>/dev/null) || HEAD_REV=
  TIP_REV=
  if DEFAULT=$(default_branch "$DIR"); then
    TIP_REV=$(git -C "$DIR" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT^{commit}" 2>/dev/null) || TIP_REV=
  fi
  if [ -z "$TIP_REV" ] || [ "$HEAD_REV" != "$TIP_REV" ]; then
    WHY=$(printf '%s\n' "$SYNC_OUT" | sed '/^[[:space:]]*$/d' | tail -n 1)
    echo "$LABEL: graph NOT refreshed: HEAD ${HEAD_REV:0:9} is not origin/${DEFAULT:-<default>} ${TIP_REV:0:9}${WHY:+ ($WHY)}"
    exit 0
  fi
  if [ -n "$(git -C "$DIR" status --porcelain --untracked-files=no 2>/dev/null | head -1)" ]; then
    echo "$LABEL: graph NOT refreshed: tracked files have uncommitted changes at origin/$DEFAULT"
    exit 0
  fi
fi

if ! NODES=$(fm_graph_reindex "$DIR" "$NAME"); then
  echo "$LABEL: graph refresh failed for project '$NAME' (mode=$MODE): $(cause); graph may be stale" >&2
  exit 0
fi

echo "$LABEL: graph refreshed (project=$NAME, mode=$MODE, nodes=${NODES:-unknown})"
