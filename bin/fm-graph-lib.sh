#!/usr/bin/env bash
# fm-graph-lib.sh - shared codebase-memory knowledge-graph primitives (sourced, not run).
#
# The one owner of how firstmate talks to the codebase-memory knowledge graph:
# where the binary is, how a tool call is made and bounded, how its output is
# parsed, and which projects the graph actually holds. bin/fm-graph-reindex.sh is
# the CLI over these helpers, and bin/fm-brief.sh sources them for the
# is-this-project-indexed check it needs at scaffold time.
#
# CLI SURFACE (verified 2026-08-10 against codebase-memory-mcp 0.8.1 at
# ~/.local/bin/codebase-memory-mcp; `--version` and `cli` with no tool are the two
# commands that print it). The same tools the MCP server exposes are reachable
# from bash, and a tool's arguments are ONE POSITIONAL JSON OBJECT:
#     codebase-memory-mcp cli [--progress] [--json] <tool> [json_args]
# There is no flag form. 0.8.1 answers `--repo_path /x` and `--repo-path /x` alike
# with `repo_path is required` on stderr and exit 1, which is what silently stalled
# every refresh until 2026-08-09; docs/graph-cli-backend.md holds that evidence.
# JSON is BUILT WITH jq, never string-concatenated, so a repo path holding a space,
# a quote, or a backslash cannot break or inject into the argument.
#
# index_repository takes repo_path (required), mode, persistence, and
# target_projects - and NO name. 0.8.1 always derives the project name from the
# resolved repo path, so a refresh lands on the recorded entry only when that
# entry's name is the derived one; fm_graph_reindex verifies this from the
# response rather than asserting it with a flag that no longer exists.
#
# The binary logs `level=info msg=... ` lines on stderr and prints its JSON payload
# on stdout, but nothing in the contract promises the payload starts at the first
# byte, so fm_graph_call tolerates non-JSON leading lines instead of assuming a
# leading `{`. On failure the diagnostic is on STDERR, which is why fm_graph_call
# captures it (see FM_GRAPH_ERR_FILE) instead of discarding it.
#
# Every helper here is BEST-EFFORT by contract: a missing binary, a missing jq, a
# CLI error, a timeout, or a project the graph does not hold is a non-zero return
# with a quiet stderr note, never a failure the caller must propagate. The graph
# is a cache; nothing in the fleet may hang or go red because it is unavailable.
# Best-effort must not mean unexplained, though: a caller that reports a failure
# names its cause, so the next breakage of this contract says what broke.
#
# READ-ONLY on project clones. `"persistence": true` writes
# .codebase-memory/graph.db.zst INTO the repository, which would dirty a clone
# firstmate must never modify, so fm_graph_reindex always passes `false`.

# --- binary resolution ------------------------------------------------------

# Echo the timeout(1) binary, or return 1 when there is none. macOS without
# coreutils has neither, and fm-watch.sh sets the precedent of trying `gtimeout`
# second. Every graph call is bounded by contract, so an unboundable call is not
# made at all: no timeout binary means "graph unavailable", not an unbounded call
# in front of a brief scaffold or a fleet sync.
fm_graph_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    printf '%s\n' timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    printf '%s\n' gtimeout
  else
    return 1
  fi
}

# Echo the codebase-memory CLI binary, or return 1 when it cannot be used.
# FM_GRAPH_CLI overrides (tests point it at a stub); otherwise PATH wins, then
# the standard user install location. jq (to read the JSON) and a timeout binary
# (to bound the call) are both required, so either one missing counts as "graph
# unavailable" rather than a separate failure mode.
fm_graph_cli() {
  local cli=${FM_GRAPH_CLI:-}
  command -v jq >/dev/null 2>&1 || return 1
  fm_graph_timeout_bin >/dev/null || return 1
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
# scaffold, a reindex does real work. Measured: list_projects 0.12-0.16s; on a
# 14,735-node clone, cold index 4.0s and incremental reindex after a merge-sized
# change 0.1-4.4s. Both defaults are ample headroom rather than working limits.
fm_graph_lookup_timeout() { printf '%s\n' "${FM_GRAPH_LOOKUP_TIMEOUT_SECS:-10}"; }
fm_graph_reindex_timeout() { printf '%s\n' "${FM_GRAPH_REINDEX_TIMEOUT_SECS:-60}"; }

# --- naming the cause of a failure ------------------------------------------

# fm_graph_note_error <text>: record why the call that just failed failed, so a
# caller can name the cause instead of reporting a bare "failed". Silent unless
# FM_GRAPH_ERR_FILE names a writable path, and the last failure wins.
#
# WHY A FILE AND NOT A GLOBAL: every caller reads these helpers through a command
# substitution, so a variable set here would die with the subshell that set it. A
# file whose path arrives by environment crosses that boundary; a variable cannot.
#
# THE BRACES ARE LOAD-BEARING: bash applies redirections left to right, so a
# `2>/dev/null` written after `> $FM_GRAPH_ERR_FILE` arrives too late to silence
# that redirection's own failure, and an unwritable path - the one case the guard
# exists for - prints raw bash noise onto fm-fleet-sync's stderr.
fm_graph_note_error() {
  [ -n "${FM_GRAPH_ERR_FILE:-}" ] || return 0
  { printf '%s\n' "$1" > "$FM_GRAPH_ERR_FILE"; } 2>/dev/null || true
}

# fm_graph_distill <stderr-file>: the CLI's own words, cut down to one line fit to
# embed in a warning. Every call logs several `level=info` progress lines, so those
# are dropped and the last two remaining lines are kept - on a tool error 0.8.1
# writes both a plain reason and its JSON error payload to stderr, and the reason
# alone is often the more useful of the two.
fm_graph_distill() {
  local msg
  msg=$(grep -v 'level=info' "$1" 2>/dev/null \
    | awk 'NF' \
    | tail -2 \
    | awk '{ printf "%s%s", sep, $0; sep = " | " } END { printf "\n" }')
  [ -n "$msg" ] || msg="no diagnostic output"
  printf '%s\n' "${msg:0:400}"
}

# --- calling the CLI --------------------------------------------------------

# fm_graph_call <timeout-secs> <tool> [json-args]: run one graph tool and print
# its JSON payload on stdout. <json-args> is the single positional JSON object the
# 0.8.1 CLI takes (see the header); omit it for a tool that needs no arguments.
# Returns non-zero when the binary is unavailable, the call fails or times out, or
# the output holds no JSON object, and notes the cause via fm_graph_note_error.
# Leading non-JSON lines (the mem.init log) are dropped rather than assumed away.
fm_graph_call() {
  local secs=$1 tool=$2 cli tmo err out json rc=0
  shift 2
  if ! cli=$(fm_graph_cli); then
    fm_graph_note_error "the codebase-memory CLI is unavailable (binary, jq, or timeout(1) missing)"
    return 1
  fi
  # Unreachable while fm_graph_cli requires a timeout binary of its own, but a
  # silent return is exactly the failure this change exists to remove, so it notes
  # a cause rather than relying on a reader proving the branch dead.
  if ! tmo=$(fm_graph_timeout_bin); then
    fm_graph_note_error "no timeout(1) binary, so the call could not be bounded"
    return 1
  fi
  if ! err=$(mktemp "${TMPDIR:-/tmp}/fm-graph-err.XXXXXX"); then
    fm_graph_note_error "could not create a temp file to capture the CLI's diagnostics"
    return 1
  fi
  out=$("$tmo" "$secs" "$cli" cli "$tool" "$@" 2>"$err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    # timeout(1) reports a killed command as 124; the stderr file holds only the
    # progress logging in that case, so the bound is the more honest cause.
    if [ "$rc" -eq 124 ]; then
      fm_graph_note_error "$tool timed out after ${secs}s"
    else
      fm_graph_note_error "$tool exited $rc: $(fm_graph_distill "$err")"
    fi
    rm -f "$err"
    return 1
  fi
  json=$(printf '%s\n' "$out" | awk '/^[[:space:]]*[{[]/ { found = 1 } found { print }')
  if [ -z "$json" ] || ! printf '%s\n' "$json" | jq -e . >/dev/null 2>&1; then
    fm_graph_note_error "$tool returned no JSON payload: $(fm_graph_distill "$err")"
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  printf '%s\n' "$json"
}

# --- project lookup ---------------------------------------------------------

# fm_graph_project_for_path <dir>: echo the graph's project NAME for the repo at
# <dir>. Matches on the resolved path, not the name: the graph derives a name from
# the path (e.g. /home/u/projects/allma-core -> home-u-projects-allma-core), so the
# directory name is not a reliable key. Both root_path and the git block's
# canonical_root are accepted, since a graph entry may be pinned to either.
#
# Two distinct failures, because they mean opposite things to a caller: 1 is "the
# graph does not hold this project", which is a normal opt-out, and 2 is "the
# lookup itself failed", which is a broken graph wearing a not-indexed disguise.
# Reporting the second as the first is how a broken CLI stays invisible.
fm_graph_project_for_path() {
  local dir=$1 abs json name
  abs=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  json=$(fm_graph_call "$(fm_graph_lookup_timeout)" list_projects) || return 2
  name=$(printf '%s\n' "$json" | jq -r --arg root "$abs" '
    [ .projects[]?
      | select((.root_path == $root) or (.git.canonical_root == $root))
      | .name ] | first // empty' 2>/dev/null) || return 2
  [ -n "$name" ] || return 1
  printf '%s\n' "$name"
}

# --- reindex ----------------------------------------------------------------

# fm_graph_reindex <dir> <project-name>: re-index an already-indexed project in
# place, so the refresh updates the recorded entry instead of creating a second
# one. Echoes the node count on success; returns 1 on any failure, having noted
# the cause via fm_graph_note_error. Never passes persistence true (see header).
#
# It passes the RESOLVED path, and then checks the project the CLI says it wrote.
# 0.8.1 has no name argument - it derives the name from the path it was handed -
# so passing the same resolved path the lookup matched on is the only way to land
# on the recorded entry, and the returned name is the only proof that it did.
# A mismatch means the refresh silently populated some other entry while the one
# firstmate reads went stale, which is worth a named failure rather than a green line.
# The proof is REQUIRED, not merely checked when offered: a response carrying no
# project is a landing nothing verified, and printing a green line for one would be
# the same unearned reassurance this whole change exists to remove. 0.8.1 always
# reports it, so requiring it costs nothing today and fails loudly if that changes.
fm_graph_reindex() {
  local dir=$1 name=$2 abs mode args json status project nodes
  mode=$(fm_graph_mode)
  [ "$mode" != off ] || return 1
  if ! abs=$(cd "$dir" 2>/dev/null && pwd -P); then
    fm_graph_note_error "could not resolve '$dir' to a directory"
    return 1
  fi
  # jq builds the argument, so a path holding a space, a quote, or a backslash is
  # carried as data rather than concatenated into a string the CLI must re-parse.
  if ! args=$(jq -nc --arg repo_path "$abs" --arg mode "$mode" \
    '{repo_path: $repo_path, mode: $mode, persistence: false}'); then
    fm_graph_note_error "could not build the index_repository arguments"
    return 1
  fi
  json=$(fm_graph_call "$(fm_graph_reindex_timeout)" index_repository "$args") || return 1
  status=$(printf '%s\n' "$json" | jq -r '.status // empty' 2>/dev/null)
  if [ "$status" != indexed ]; then
    fm_graph_note_error "index_repository reported status='${status:-none}'$(
      printf '%s\n' "$json" | jq -r 'if .hint then " (" + .hint + ")" else "" end' 2>/dev/null)"
    return 1
  fi
  project=$(printf '%s\n' "$json" | jq -r '.project // empty' 2>/dev/null)
  if [ -z "$project" ]; then
    fm_graph_note_error "the CLI reported no project for the refresh, so nothing proves '$name' is the entry it wrote"
    return 1
  fi
  if [ "$project" != "$name" ]; then
    fm_graph_note_error "the refresh landed on project '$project', not the recorded '$name', so '$name' is still stale"
    return 1
  fi
  nodes=$(printf '%s\n' "$json" | jq -r '.nodes // empty' 2>/dev/null)
  printf '%s\n' "$nodes"
}
