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
# BEST-EFFORT BY CONTRACT, and it exits 0 on every graph outcome so no caller can
# go red because a cache is unavailable. A refresh that succeeds prints one
# "<project>: graph refreshed ..." line on stdout; every skip and every failure
# warns on stderr and is otherwise silent, so a session-start fleet refresh (which
# relays stdout) stays quiet unless something actually happened.
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

if ! NAME=$(fm_graph_project_for_path "$DIR"); then
  echo "$LABEL: graph skipped: not found in the graph (index it once to opt in to refreshes)" >&2
  exit 0
fi

if ! NODES=$(fm_graph_reindex "$DIR" "$NAME"); then
  echo "$LABEL: graph refresh failed for project '$NAME' (mode=$MODE); graph may be stale" >&2
  exit 0
fi

echo "$LABEL: graph refreshed (project=$NAME, mode=$MODE, nodes=${NODES:-unknown})"
