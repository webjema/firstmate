#!/usr/bin/env bash
# fm-graph-lib.sh - shared codebase-memory knowledge-graph primitives (sourced, not run).
#
# The one owner of how firstmate talks to the codebase-memory knowledge graph:
# where the binary is, how a tool call is made and bounded, how its output is
# parsed, and which projects the graph actually holds. bin/fm-graph-reindex.sh is
# the CLI over these helpers, and bin/fm-brief.sh sources them for the
# is-this-project-indexed check it needs at scaffold time.
#
# CLI SURFACE (verified 2026-07-29 against the binary at ~/.local/bin/codebase-memory-mcp).
# The same tools the MCP server exposes are reachable from bash:
#     codebase-memory-mcp cli <tool> --flag value [--flag value ...]
# Passing raw JSON positionally is deprecated and warns, so every call here uses
# flags. The binary logs `level=info msg=mem.init ...` (and any deprecation
# warning) on stderr and prints its JSON payload on stdout, but nothing in the
# contract promises the payload starts at the first byte, so fm_graph_call
# tolerates non-JSON leading lines instead of assuming a leading `{`.
#
# Every helper here is BEST-EFFORT by contract: a missing binary, a missing jq, a
# CLI error, a timeout, or a project the graph does not hold is a non-zero return
# with a quiet stderr note, never a failure the caller must propagate. The graph
# is a cache; nothing in the fleet may hang or go red because it is unavailable.
#
# READ-ONLY on project clones. `index_repository --persistence true` writes
# .codebase-memory/graph.db.zst INTO the repository, which would dirty a clone
# firstmate must never modify, so fm_graph_reindex always passes `false`.

# --- binary resolution ------------------------------------------------------

# Echo the codebase-memory CLI binary, or return 1 when it cannot be used.
# FM_GRAPH_CLI overrides (tests point it at a stub); otherwise PATH wins, then
# the standard user install location. jq is required to read the JSON, so its
# absence counts as "graph unavailable" rather than a separate failure mode.
fm_graph_cli() {
  local cli=${FM_GRAPH_CLI:-}
  command -v jq >/dev/null 2>&1 || return 1
  if [ -n "$cli" ]; then
    [ -x "$cli" ] || command -v "$cli" >/dev/null 2>&1 || return 1
    printf '%s\n' "$cli"
    return 0
  fi
  if command -v codebase-memory-mcp >/dev/null 2>&1; then
    printf '%s\n' codebase-memory-mcp
    return 0
  fi
  if [ -x "$HOME/.local/bin/codebase-memory-mcp" ]; then
    printf '%s\n' "$HOME/.local/bin/codebase-memory-mcp"
    return 0
  fi
  return 1
}

# --- knobs ------------------------------------------------------------------

# Effective index mode: FM_GRAPH_REINDEX_MODE -> config/graph-reindex-mode -> full.
# `full` is the default deliberately: on thecompany, `moderate` silently excluded
# tools/, scripts/, and the migration and terraform-fixture trees - 9,080 nodes
# against full's 14,735 - and a graph that silently lacks the code being asked
# about is worse than no graph. `off` is the feature's kill switch: it disables
# both the refresh and the brief's graph guidance, so firstmate neither maintains
# the graph nor points crews at one it is not maintaining. An unrecognized value
# warns and falls back to full.
fm_graph_mode() {
  local cfg val
  val=${FM_GRAPH_REINDEX_MODE:-}
  if [ -z "$val" ]; then
    cfg="${FM_CONFIG_OVERRIDE:-${FM_HOME:-${FM_ROOT:-.}}/config}/graph-reindex-mode"
    if [ -f "$cfg" ]; then
      val=$(grep -vE '^[[:space:]]*(#|$)' "$cfg" 2>/dev/null | head -1 | tr -d '[:space:]') || true
    fi
  fi
  [ -n "$val" ] || val=full
  case "$val" in
    full|moderate|fast|cross-repo-intelligence|off) printf '%s\n' "$val" ;;
    *)
      echo "graph: unknown index mode '$val'; using full" >&2
      printf '%s\n' full
      ;;
  esac
}

# Seconds a single CLI call may take before it is killed. Two bounds because the
# two callers have very different budgets: a lookup sits in front of a brief
# scaffold, a reindex does real work. Measured on a 14,735-node clone: cold index
# 4.0s, incremental reindex after a merge-sized change 0.1-4.4s, so the reindex
# default is ample headroom rather than a working limit.
fm_graph_lookup_timeout() { printf '%s\n' "${FM_GRAPH_LOOKUP_TIMEOUT_SECS:-10}"; }
fm_graph_reindex_timeout() { printf '%s\n' "${FM_GRAPH_REINDEX_TIMEOUT_SECS:-60}"; }

# --- calling the CLI --------------------------------------------------------

# fm_graph_call <timeout-secs> <tool> [flag value ...]: run one graph tool and
# print its JSON payload on stdout. Returns non-zero when the binary is
# unavailable, the call fails or times out, or the output holds no JSON object.
# Leading non-JSON lines (the mem.init log, a deprecation warning) are dropped
# rather than assumed away.
fm_graph_call() {
  local secs=$1 tool=$2 cli out json
  shift 2
  cli=$(fm_graph_cli) || return 1
  out=$(timeout "$secs" "$cli" cli "$tool" "$@" 2>/dev/null) || return 1
  json=$(printf '%s\n' "$out" | awk '/^[[:space:]]*[{[]/ { found = 1 } found { print }')
  [ -n "$json" ] || return 1
  printf '%s\n' "$json" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s\n' "$json"
}

# --- project lookup ---------------------------------------------------------

# fm_graph_project_for_path <dir>: echo the graph's project NAME for the repo at
# <dir>, or return 1 when the graph does not hold it (or is unavailable). Matches
# on the resolved path, not the name: the graph derives a name from the path when
# none was given (e.g. /home/u/projects/allma-core -> home-u-projects-allma-core),
# so the directory name is not a reliable key. Both root_path and the git block's
# canonical_root are accepted, since a graph entry may be pinned to either.
fm_graph_project_for_path() {
  local dir=$1 abs json name
  abs=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  json=$(fm_graph_call "$(fm_graph_lookup_timeout)" list_projects) || return 1
  name=$(printf '%s\n' "$json" | jq -r --arg root "$abs" '
    [ .projects[]?
      | select((.root_path == $root) or (.git.canonical_root == $root))
      | .name ] | first // empty' 2>/dev/null) || return 1
  [ -n "$name" ] || return 1
  printf '%s\n' "$name"
}

# --- reindex ----------------------------------------------------------------

# fm_graph_reindex <dir> <project-name>: re-index an already-indexed project in
# place under its recorded name, so the refresh updates that entry instead of
# creating a second path-derived one. Echoes the node count on success; returns 1
# on any failure. Never passes --persistence true (see the header).
fm_graph_reindex() {
  local dir=$1 name=$2 mode json status
  mode=$(fm_graph_mode)
  [ "$mode" != off ] || return 1
  json=$(fm_graph_call "$(fm_graph_reindex_timeout)" index_repository \
    --repo-path "$dir" --name "$name" --mode "$mode" --persistence false) || return 1
  status=$(printf '%s\n' "$json" | jq -r '.status // empty' 2>/dev/null)
  [ "$status" = indexed ] || return 1
  printf '%s\n' "$(printf '%s\n' "$json" | jq -r '.nodes // empty' 2>/dev/null)"
}
