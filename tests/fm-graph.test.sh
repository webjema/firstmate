#!/usr/bin/env bash
# Behavior tests for bin/fm-graph-reindex.sh and the bin/fm-graph-lib.sh contract
# it is the CLI over.
#
# The load-bearing property is that NOTHING here may ever fail its caller. The
# graph is a cache, and fm-fleet-sync.sh calls this from firstmate's wake-handling
# path, so a missing binary, an unindexed project, a CLI error, a garbage payload,
# or a hung CLI must each end in a warning and exit 0 - never a red sync. Every
# failure mode below is pinned for that reason.
#
# Two other invariants are pinned because violating them is silently expensive:
#   - an unindexed project is SKIPPED, never indexed (a first index of a large repo
#     is slow, and opting a project in is a decision, not a merge side effect), so
#     no index_repository call may be made for one;
#   - --persistence is always false, because `true` writes
#     .codebase-memory/graph.db.zst INTO the repo and would dirty a clone firstmate
#     must never modify.
set -u

# shellcheck source=tests/graph-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/graph-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-graph)
STUB=$(fm_graph_stub "$TMP_ROOT/bin")

# new_case: fresh isolated home; echoes "<home> <repo>" where <repo> is a project
# clone under that home's projects/ dir. mktemp, not a counter: every caller reads
# this through a command substitution, so a counter would increment in a subshell
# and hand every test the same dir - and a shared call log makes the
# never-index-an-unindexed-project assertion pass or fail on test order.
new_case() {
  local home
  home=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  mkdir -p "$home/projects/proj" "$home/config"
  printf '%s %s\n' "$home" "$home/projects/proj"
}

# run_reindex <home> <arg>: run the reindex entry point with the stub wired in.
# Echoes stdout; stderr lands in <home>/stderr.log so warnings can be asserted (it
# runs in a command substitution, so it cannot hand a path back in a variable).
run_reindex() {
  local home=$1 arg=$2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_GRAPH_CLI="${FM_GRAPH_CLI_OVERRIDE:-$STUB}" \
    "$ROOT/bin/fm-graph-reindex.sh" "$arg" 2> "$home/stderr.log"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-graph-reindex.sh" --help 2>&1)
  assert_contains "$help" "single owner" "fm-graph-reindex.sh --help omitted its header terminator"
  pass "fm-graph-reindex.sh: --help renders the complete header"
}

# The happy path, plus the two invariants that make it safe: the recorded project
# name is reused (not the directory name) and --persistence is false.
test_refreshes_indexed_project() {
  local home repo out log
  read -r home repo <<<"$(new_case)"
  log="$home/calls.log"
  fm_graph_stub_projects "$home/projects.json" derived-graph-name "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$log" run_reindex "$home" "$repo")
  assert_contains "$out" "proj: graph refreshed" "a refreshed project must report on stdout"
  assert_contains "$out" "project=derived-graph-name" "the refresh must name the graph's project, not the directory"
  assert_contains "$out" "mode=full" "full must be the default index mode"
  assert_contains "$out" "nodes=4321" "the refresh must report the node count it got back"
  assert_grep "index_repository" "$log" "an indexed project must be re-indexed"
  assert_grep "--name derived-graph-name" "$log" "the reindex must reuse the recorded project name"
  assert_grep "--persistence false" "$log" "the reindex must never persist an artifact into the repo"
  assert_no_grep "--persistence true" "$log" "--persistence true would dirty a read-only clone"
  pass "fm-graph-reindex.sh: refreshes an indexed project in place with persistence off"
}

# Non-JSON leading output (the real binary's mem.init log, a deprecation warning)
# must be tolerated, not assumed away.
test_tolerates_non_json_leading_output() {
  local home repo out
  read -r home repo <<<"$(new_case)"
  fm_graph_stub_projects "$home/projects.json" noisy-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_NOISE=1 run_reindex "$home" "$repo")
  assert_contains "$out" "project=noisy-proj" "leading non-JSON lines must not defeat the parser"
  pass "fm-graph-reindex.sh: tolerates non-JSON leading output on stdout"
}

# The lookup keys on the resolved path, so a graph entry pinned to a canonical root
# still matches when root_path names a worktree of it.
test_matches_on_canonical_root() {
  local home repo out
  read -r home repo <<<"$(new_case)"
  fm_graph_stub_projects_canonical_only "$home/projects.json" canonical-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" run_reindex "$home" "$repo")
  assert_contains "$out" "project=canonical-proj" "a canonical-root match must be found"
  pass "fm-graph-reindex.sh: matches a project on its canonical root"
}

# A bare project name resolves against the home's projects/ dir, like fleet sync's.
test_resolves_bare_project_name() {
  local home repo out
  read -r home repo <<<"$(new_case)"
  fm_graph_stub_projects "$home/projects.json" bare-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" run_reindex "$home" proj)
  assert_contains "$out" "project=bare-proj" "a bare <name> must resolve against projects/"
  pass "fm-graph-reindex.sh: resolves a bare project name against projects/"
}

# --- non-fatal failure paths ------------------------------------------------

test_unindexed_project_is_skipped_not_indexed() {
  local home repo out code log
  read -r home repo <<<"$(new_case)"
  log="$home/calls.log"
  fm_graph_stub_projects "$home/projects.json" someone-else /somewhere/else
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$log" run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "an unindexed project must not fail the caller"
  [ -z "$out" ] || fail "an unindexed project must print nothing on stdout, got: $out"
  assert_grep "not found in the graph" "$home/stderr.log" "an unindexed project must warn on stderr"
  assert_no_grep "index_repository" "$log" "an unindexed project must never be indexed as a side effect"
  pass "fm-graph-reindex.sh: skips (never indexes) a project the graph does not hold"
}

test_missing_binary_is_non_fatal() {
  local home repo out code
  read -r home repo <<<"$(new_case)"
  out=$(FM_GRAPH_CLI_OVERRIDE="$TMP_ROOT/no-such-binary" run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "a missing codebase-memory binary must not fail the caller"
  [ -z "$out" ] || fail "a missing binary must print nothing on stdout, got: $out"
  assert_grep "CLI unavailable" "$home/stderr.log" "a missing binary must warn on stderr"
  pass "fm-graph-reindex.sh: a missing binary warns and exits 0"
}

test_lookup_error_is_non_fatal() {
  local home repo out code
  read -r home repo <<<"$(new_case)"
  fm_graph_stub_projects "$home/projects.json" erroring-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_FAIL=list_projects run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "a failing list_projects must not fail the caller"
  [ -z "$out" ] || fail "a failing lookup must print nothing on stdout, got: $out"
  assert_grep "not found in the graph" "$home/stderr.log" "a failing lookup must warn on stderr"
  pass "fm-graph-reindex.sh: a CLI error during lookup warns and exits 0"
}

test_index_error_is_non_fatal() {
  local home repo out code
  read -r home repo <<<"$(new_case)"
  fm_graph_stub_projects "$home/projects.json" failing-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_FAIL=index_repository run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "a failing index_repository must not fail the caller"
  [ -z "$out" ] || fail "a failed refresh must print nothing on stdout, got: $out"
  assert_grep "graph refresh failed" "$home/stderr.log" "a failed refresh must warn on stderr"
  assert_grep "may be stale" "$home/stderr.log" "a failed refresh must say the graph may be stale"
  pass "fm-graph-reindex.sh: a CLI error during reindex warns and exits 0"
}

test_garbage_payload_is_non_fatal() {
  local home repo out code
  read -r home repo <<<"$(new_case)"
  printf 'not json at all\n' > "$home/projects.json"
  out=$(FM_STUB_PROJECTS="$home/projects.json" run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "an unparseable payload must not fail the caller"
  assert_grep "not found in the graph" "$home/stderr.log" "an unparseable payload must warn on stderr"
  pass "fm-graph-reindex.sh: an unparseable payload warns and exits 0"
}

# A hung CLI must be bounded, not waited on: fleet sync runs on the wake-handling
# path, and the bound is what keeps the call from wedging supervision.
test_hung_cli_is_bounded() {
  local home repo out code
  read -r home repo <<<"$(new_case)"
  fm_graph_stub_projects "$home/projects.json" hung-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_SLEEP=10 FM_GRAPH_LOOKUP_TIMEOUT_SECS=1 \
    run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "a hung CLI must not fail the caller"
  [ -z "$out" ] || fail "a hung CLI must print nothing on stdout, got: $out"
  pass "fm-graph-reindex.sh: a hung CLI is bounded by its timeout and exits 0"
}

test_missing_directory_is_non_fatal() {
  local home repo out code
  read -r home repo <<<"$(new_case)"
  out=$(run_reindex "$home" "$home/no-such-dir"); code=$?
  expect_code 0 "$code" "a missing directory must not fail the caller"
  assert_grep "not a directory" "$home/stderr.log" "a missing directory must warn on stderr"
  pass "fm-graph-reindex.sh: a missing project directory warns and exits 0"
}

# --- the mode knob ----------------------------------------------------------

test_mode_from_config_file() {
  local home repo log
  read -r home repo <<<"$(new_case)"
  log="$home/calls.log"
  fm_graph_stub_projects "$home/projects.json" moded-proj "$repo"
  printf '# comment\nfast\n' > "$home/config/graph-reindex-mode"
  FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$log" run_reindex "$home" "$repo" >/dev/null
  assert_grep "--mode fast" "$log" "config/graph-reindex-mode must select the index mode"
  pass "fm-graph-reindex.sh: config/graph-reindex-mode selects the mode"
}

test_env_overrides_config_mode() {
  local home repo log
  read -r home repo <<<"$(new_case)"
  log="$home/calls.log"
  fm_graph_stub_projects "$home/projects.json" moded-proj "$repo"
  printf 'fast\n' > "$home/config/graph-reindex-mode"
  FM_GRAPH_REINDEX_MODE=moderate FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$log" \
    run_reindex "$home" "$repo" >/dev/null
  assert_grep "--mode moderate" "$log" "FM_GRAPH_REINDEX_MODE must override the config file"
  pass "fm-graph-reindex.sh: FM_GRAPH_REINDEX_MODE overrides the config file"
}

test_unknown_mode_falls_back_to_full() {
  local home repo log
  read -r home repo <<<"$(new_case)"
  log="$home/calls.log"
  fm_graph_stub_projects "$home/projects.json" moded-proj "$repo"
  printf 'sideways\n' > "$home/config/graph-reindex-mode"
  FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$log" run_reindex "$home" "$repo" >/dev/null
  assert_grep "--mode full" "$log" "an unknown mode must fall back to full"
  assert_grep "unknown index mode" "$home/stderr.log" "an unknown mode must warn"
  pass "fm-graph-reindex.sh: an unknown mode warns and falls back to full"
}

test_mode_off_disables_refresh() {
  local home repo out log
  read -r home repo <<<"$(new_case)"
  log="$home/calls.log"
  fm_graph_stub_projects "$home/projects.json" off-proj "$repo"
  out=$(FM_GRAPH_REINDEX_MODE=off FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$log" \
    run_reindex "$home" "$repo")
  [ -z "$out" ] || fail "mode=off must print nothing on stdout, got: $out"
  assert_grep "refresh disabled" "$home/stderr.log" "mode=off must say so on stderr"
  assert_absent "$log" "mode=off must not call the graph CLI at all"
  pass "fm-graph-reindex.sh: mode=off is a complete kill switch"
}

test_help_includes_entire_header
test_refreshes_indexed_project
test_tolerates_non_json_leading_output
test_matches_on_canonical_root
test_resolves_bare_project_name
test_unindexed_project_is_skipped_not_indexed
test_missing_binary_is_non_fatal
test_lookup_error_is_non_fatal
test_index_error_is_non_fatal
test_garbage_payload_is_non_fatal
test_hung_cli_is_bounded
test_missing_directory_is_non_fatal
test_mode_from_config_file
test_env_overrides_config_mode
test_unknown_mode_falls_back_to_full
test_mode_off_disables_refresh
