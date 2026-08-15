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
#   - persistence is always false, because `true` writes
#     .codebase-memory/graph.db.zst INTO the repo and would dirty a clone firstmate
#     must never modify.
#
# THE INVOCATION IS PINNED TO THE REAL BINARY, not to the string we build. On
# 2026-08-09 the flag form bin/fm-graph-lib.sh had used for a fortnight stopped
# being one the CLI accepted, and every refresh failed non-fatally and silently -
# a suite that only asserted the string we build would have stayed green through
# all of it. So the argument shape is checked two ways: the stub refuses a --flag,
# holding firstmate's own invocation to the JSON form, and test_real_cli_* drives the
# installed binary end to end against a throwaway repo and graph cache, skipping
# cleanly when it is absent - including a check that it is still the version
# docs/graph-cli-backend.md records as verified.
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

# derived_for <dir>: the name the binary would slug out of <dir>'s resolved path if
# it were handed no name (see fm_graph_derived_name). Two uses, and only two: a
# fixture for the common entry whose recorded name IS the slug, and - in the tests
# below that turn on addressing - the name a refresh must NOT land on.
derived_for() { fm_graph_derived_name "$(cd "$1" && pwd -P)"; }

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-graph-reindex.sh" --help 2>&1)
  assert_contains "$help" "single owner" "fm-graph-reindex.sh --help omitted its header terminator"
  pass "fm-graph-reindex.sh: --help renders the complete header"
}

# The happy path, plus the two invariants that make it safe: the refresh lands on
# the recorded project (not a second, path-derived one) and persistence is false.
test_refreshes_indexed_project() {
  local home repo out log name
  read -r home repo <<<"$(new_case)"
  log="$home/calls.log"
  name=$(derived_for "$repo")
  fm_graph_stub_projects "$home/projects.json" "$name" "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$log" run_reindex "$home" "$repo")
  assert_contains "$out" "proj: graph refreshed" "a refreshed project must report on stdout"
  assert_contains "$out" "project=$name" "the refresh must name the graph's project, not the directory"
  assert_contains "$out" "mode=full" "full must be the default index mode"
  assert_contains "$out" "nodes=4321" "the refresh must report the node count it got back"
  assert_grep "index_repository" "$log" "an indexed project must be re-indexed"
  assert_grep '"persistence":false' "$log" "the reindex must never persist an artifact into the repo"
  assert_no_grep '"persistence":true' "$log" "persistence true would dirty a read-only clone"
  pass "fm-graph-reindex.sh: refreshes an indexed project in place with persistence off"
}

# --- the argument surface ---------------------------------------------------

# The 2026-08-09 regression in one assertion. It pins what firstmate builds, not what
# the installed binary tolerates, which is why it survives the surface moving.
test_arguments_are_one_json_object_not_flags() {
  local home repo log args
  read -r home repo <<<"$(new_case)"
  log="$home/calls.log"
  fm_graph_stub_projects "$home/projects.json" "$(derived_for "$repo")" "$repo"
  FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$log" run_reindex "$home" "$repo" >/dev/null
  assert_no_grep "index_repository --" "$log" "no graph call may pass a flag; JSON is the shape every version takes"
  args=$(sed -n 's/^index_repository //p' "$log")
  printf '%s' "$args" | jq -e . >/dev/null 2>&1 \
    || fail "index_repository must be handed one parseable JSON object, got: $args"
  [ "$(printf '%s' "$args" | jq -r '.repo_path')" = "$(cd "$repo" && pwd -P)" ] \
    || fail "repo_path must carry the resolved repo path, got: $args"
  [ "$(printf '%s' "$args" | jq -r '.mode')" = full ] || fail "mode must ride in the JSON, got: $args"
  [ "$(printf '%s' "$args" | jq -r '.persistence')" = false ] || fail "persistence must ride in the JSON, got: $args"
  pass "fm-graph-lib.sh: a tool call is one positional JSON object, never flags"
}

# --- addressing the recorded entry ------------------------------------------
#
# The defect these pin: for a project whose recorded name is not the slug of its
# clone path, a refresh that sends only the path lands on the slug, and the recorded
# entry - the one every brief points its crew at - is never refreshed at all.
# docs/graph-cli-backend.md's "unreachable entry" incident holds the live case.

# The fix in one assertion: the name the lookup read out of the graph is what the
# refresh is addressed by, so the entry firstmate reads is the entry that moves.
test_refresh_addresses_the_recorded_name() {
  local home repo out log args
  read -r home repo <<<"$(new_case)"
  log="$home/calls.log"
  fm_graph_stub_projects "$home/projects.json" recorded-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$log" run_reindex "$home" "$repo")
  args=$(sed -n 's/^index_repository //p' "$log")
  [ "$(printf '%s' "$args" | jq -r '.name')" = recorded-proj ] \
    || fail "the refresh must be addressed by the graph's recorded name, got: $args"
  assert_contains "$out" "project=recorded-proj" "the refresh must land on the recorded entry"
  assert_not_contains "$out" "$(derived_for "$repo")" \
    "the refresh must not land on the slug of the clone path"
  assert_no_grep "graph refresh failed" "$home/stderr.log" \
    "a project whose recorded name is not the path slug must still refresh"
  pass "fm-graph-reindex.sh: the refresh is addressed by the name the graph records"
}

# A path holding a space (or a quote) must survive as data. jq builds the argument
# for exactly this reason: concatenating one into a string would split or inject.
test_path_with_space_is_passed_intact() {
  local home repo out log args name
  home=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  repo="$home/projects/a proj \"quoted\""
  mkdir -p "$repo" "$home/config"
  log="$home/calls.log"
  name=$(derived_for "$repo")
  fm_graph_stub_projects "$home/projects.json" "$name" "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$log" run_reindex "$home" "$repo")
  assert_contains "$out" "project=$name" "a path with a space must still resolve and refresh"
  args=$(sed -n 's/^index_repository //p' "$log")
  [ "$(printf '%s' "$args" | jq -r '.repo_path')" = "$(cd "$repo" && pwd -P)" ] \
    || fail "a spaced/quoted path must arrive whole, got: $args"
  pass "fm-graph-lib.sh: a repo path holding a space and a quote is passed intact"
}

# Non-JSON leading output (the real binary's mem.init log, a deprecation warning)
# must be tolerated, not assumed away.
test_tolerates_non_json_leading_output() {
  local home repo out name
  read -r home repo <<<"$(new_case)"
  name=$(derived_for "$repo")
  fm_graph_stub_projects "$home/projects.json" "$name" "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_NOISE=1 run_reindex "$home" "$repo")
  assert_contains "$out" "project=$name" "leading non-JSON lines must not defeat the parser"
  pass "fm-graph-reindex.sh: tolerates non-JSON leading output on stdout"
}

# The lookup keys on the resolved path and accepts a match on git.canonical_root, so
# an entry recorded against a worktree is FOUND under the canonical clone - and now
# refreshed, because the name comes from the entry that matched rather than from the
# path being sent. This case used to assert the opposite and named the reason: the
# binary slugged the clone path and tripped the mismatch guard, leaving an entry
# firstmate could see but never refresh. The condition is live, not latent - 0.9.0's
# list_projects carries the git block that supplies a canonical_root, where 0.8.1's
# carried none.
test_canonical_root_match_refreshes_the_recorded_entry() {
  local home repo out
  read -r home repo <<<"$(new_case)"
  fm_graph_stub_projects_canonical_only "$home/projects.json" canonical-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" run_reindex "$home" "$repo")
  assert_contains "$out" "project=canonical-proj" \
    "an entry matched on its canonical root must be refreshed under its own name"
  assert_no_grep "graph refresh failed" "$home/stderr.log" \
    "a canonical-root match is reachable now that the name addresses it"
  pass "fm-graph-reindex.sh: a canonical-root-only entry is found and refreshed in place"
}

# A bare project name resolves against the home's projects/ dir, like fleet sync's.
test_resolves_bare_project_name() {
  local home repo out name
  read -r home repo <<<"$(new_case)"
  name=$(derived_for "$repo")
  fm_graph_stub_projects "$home/projects.json" "$name" "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" run_reindex "$home" proj)
  assert_contains "$out" "project=$name" "a bare <name> must resolve against projects/"
  pass "fm-graph-reindex.sh: resolves a bare project name against projects/"
}

# --- non-fatal failure paths ------------------------------------------------

# fm_graph_note_error's contract is "silent unless FM_GRAPH_ERR_FILE names a
# WRITABLE path", and the unwritable case is the only one the guard exists for.
# Bash applies redirections left to right, so a `2>/dev/null` that follows the
# output redirection cannot silence that redirection's own failure - the shell's
# own "No such file or directory" then lands on fm-fleet-sync's stderr, which
# firstmate relays to the user as a diagnostic nobody can act on.
test_note_error_is_silent_when_the_file_is_unwritable() {
  local home noise code
  read -r home _ <<<"$(new_case)"
  noise=$(FM_GRAPH_ERR_FILE="$home/no/such/dir/err" bash -c \
    '. "$1/bin/fm-graph-lib.sh"; fm_graph_note_error boom' _ "$ROOT" 2>&1); code=$?
  expect_code 0 "$code" "an unwritable error file must not fail its caller"
  [ -z "$noise" ] || fail "an unwritable error file must produce no output, got: $noise"
  pass "fm-graph-lib.sh: an unwritable FM_GRAPH_ERR_FILE stays silent, bash noise and all"
}

# The never-index-an-unheld-project rule, load-bearing now that `name` can CREATE an
# entry (bin/fm-graph-lib.sh's header owns why): no entry, no name, no call.
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

# The same rule one layer down, so it does not rest on the caller alone.
test_reindex_refuses_an_empty_name() {
  local home repo log code
  read -r home repo <<<"$(new_case)"
  log="$home/calls.log"
  # The mode is pinned rather than inherited: fm_graph_mode resolves its config file
  # against the invoking cwd here, and a `off` there would return before the guard,
  # passing both assertions for the wrong reason.
  FM_GRAPH_CLI="$STUB" FM_STUB_LOG="$log" FM_GRAPH_REINDEX_MODE=full bash -c \
    '. "$1/bin/fm-graph-lib.sh"; fm_graph_reindex "$2" ""' _ "$ROOT" "$repo" >/dev/null 2>&1
  code=$?
  expect_code 1 "$code" "an empty project name must be refused"
  [ ! -s "$log" ] || fail "an empty name must never reach the CLI, got: $(cat "$log")"
  pass "fm-graph-lib.sh: refuses an empty project name rather than slugging the path"
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

# A restricted PATH with everything the script needs EXCEPT the named tool, so
# "the graph is unavailable" can be proved rather than assumed. Mirrors
# tests/fm-cd-pretool-check.test.sh's missing-node/missing-jq cases.
path_without() {
  local missing=$1 dir=$2 tool tool_path
  mkdir -p "$dir"
  for tool in bash sh env git jq awk grep head tr basename dirname cat printf sed timeout gtimeout; do
    [ "$tool" != "$missing" ] || continue
    tool_path=$(command -v "$tool") || continue
    ln -sf "$tool_path" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

test_missing_jq_is_non_fatal() {
  local home repo out code bin
  read -r home repo <<<"$(new_case)"
  bin=$(path_without jq "$home/nojq")
  fm_graph_stub_projects "$home/projects.json" jqless-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" PATH="$bin" run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "a missing jq must not fail the caller"
  [ -z "$out" ] || fail "a missing jq must print nothing on stdout, got: $out"
  assert_grep "CLI unavailable" "$home/stderr.log" "a missing jq must report the graph unavailable"
  pass "fm-graph-reindex.sh: a missing jq reports the graph unavailable and exits 0"
}

# No timeout(1) and no gtimeout means a call cannot be BOUNDED, and an unbounded
# graph call in front of a fleet sync is exactly what the contract forbids - so
# the graph counts as unavailable instead.
test_missing_timeout_binary_is_non_fatal() {
  local home repo out code bin
  read -r home repo <<<"$(new_case)"
  bin=$(path_without timeout "$home/notimeout")
  rm -f "$bin/gtimeout"
  fm_graph_stub_projects "$home/projects.json" unbounded-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$home/calls.log" \
    PATH="$bin" run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "no timeout binary must not fail the caller"
  [ -z "$out" ] || fail "no timeout binary must print nothing on stdout, got: $out"
  assert_grep "CLI unavailable" "$home/stderr.log" "no timeout binary must report the graph unavailable"
  [ ! -f "$home/calls.log" ] || fail "an unboundable call must never be made"
  pass "fm-graph-reindex.sh: with no timeout binary the graph is unavailable, not unbounded"
}

# A broken CLI is not an unindexed project, and saying "index it once to opt in"
# to someone whose project IS indexed is how the 2026-08-09 breakage hid.
test_lookup_error_is_non_fatal_and_named() {
  local home repo out code
  read -r home repo <<<"$(new_case)"
  fm_graph_stub_projects "$home/projects.json" erroring-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_FAIL=list_projects run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "a failing list_projects must not fail the caller"
  [ -z "$out" ] || fail "a failing lookup must print nothing on stdout, got: $out"
  assert_grep "could not read the graph's project list" "$home/stderr.log" \
    "a failing lookup must say the lookup failed"
  assert_grep "stub: list_projects failed" "$home/stderr.log" \
    "a failing lookup must quote what the CLI said"
  assert_no_grep "index it once" "$home/stderr.log" \
    "a broken CLI must not be reported as an unindexed project"
  pass "fm-graph-reindex.sh: a CLI error during lookup names its cause and exits 0"
}

# The regression's central lesson: non-fatal must not mean unexplained. A warning
# that says only "failed" is indistinguishable from noise, and was ignored twice in
# one session; the CLI's own words are what make the next breakage self-describing.
test_index_error_is_non_fatal_and_names_its_cause() {
  local home repo out code
  read -r home repo <<<"$(new_case)"
  fm_graph_stub_projects "$home/projects.json" failing-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_FAIL=index_repository run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "a failing index_repository must not fail the caller"
  [ -z "$out" ] || fail "a failed refresh must print nothing on stdout, got: $out"
  assert_grep "graph refresh failed" "$home/stderr.log" "a failed refresh must warn on stderr"
  assert_grep "may be stale" "$home/stderr.log" "a failed refresh must say the graph may be stale"
  assert_grep "stub: index_repository failed" "$home/stderr.log" \
    "a failed refresh must quote the CLI's own diagnostic"
  pass "fm-graph-reindex.sh: a CLI error during reindex names its cause and exits 0"
}

# The wrong-argument-surface failure itself, from the caller's side: a CLI that
# rejects what it was handed must produce a warning that repeats the rejection.
test_rejected_arguments_are_reported_verbatim() {
  local home repo out code stub
  read -r home repo <<<"$(new_case)"
  # A stub that refuses everything the way 0.8.1 refuses a flag call.
  stub="$home/refusing-cli"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
echo "level=info msg=mem.init budget_mb=3904 total_ram_mb=15617" >&2
[ "${2:-}" = list_projects ] || { echo "repo_path is required" >&2; exit 1; }
cat "${FM_STUB_PROJECTS:-/dev/null}"
SH
  chmod +x "$stub"
  fm_graph_stub_projects "$home/projects.json" refused-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_GRAPH_CLI_OVERRIDE="$stub" \
    run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "a rejected call must not fail the caller"
  [ -z "$out" ] || fail "a rejected call must print nothing on stdout, got: $out"
  assert_grep "repo_path is required" "$home/stderr.log" \
    "the CLI's rejection must reach the warning verbatim"
  assert_no_grep "level=info" "$home/stderr.log" \
    "the CLI's progress logging must not drown the cause it is quoted alongside"
  pass "fm-graph-reindex.sh: a CLI that rejects the arguments says so in the warning"
}

# Asking for the recorded entry is not the same as reaching it, so the landing is
# verified from the response whatever was asked for. A refresh that populated some
# OTHER entry left the one firstmate reads stale, which is a failure however healthy
# the CLI's own "indexed" looked. This is also the guard that keeps the `name`
# argument honest against a binary that ignores it - 0.8.1 and anything older - which
# reaches this same branch having silently landed on the path slug instead.
test_refresh_landing_on_another_project_fails_loudly() {
  local home repo out code
  read -r home repo <<<"$(new_case)"
  fm_graph_stub_projects "$home/projects.json" recorded-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_INDEX_PROJECT=some-other-proj \
    run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "a mislanded refresh must not fail the caller"
  [ -z "$out" ] || fail "a mislanded refresh must not claim success, got: $out"
  assert_grep "graph refresh failed" "$home/stderr.log" "a mislanded refresh must warn"
  assert_grep "some-other-proj" "$home/stderr.log" "the warning must name where the refresh landed"
  assert_grep "recorded-proj" "$home/stderr.log" "the warning must name the entry left stale"
  pass "fm-graph-reindex.sh: a refresh that lands on another project is a named failure"
}

# The same guard from the other side, and the sharper case: a response that names NO
# project proves nothing at all about where the refresh landed. Treating that as
# success prints a green "graph refreshed" line asserting a landing nobody verified,
# which is worse than the bare warning it replaced - it is this PR's own thesis
# (a check that cannot detect its own failure) reproduced one layer down. Both 0.8.1
# and 0.9.0 report the project, so this pins the contract against a binary that stops.
test_refresh_without_a_project_fails_loudly() {
  local home repo out code
  read -r home repo <<<"$(new_case)"
  fm_graph_stub_projects "$home/projects.json" "$(derived_for "$repo")" "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_INDEX_NO_PROJECT=1 \
    run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "an unverifiable refresh must not fail the caller"
  [ -z "$out" ] || fail "an unverified landing must not print a green line, got: $out"
  assert_grep "graph refresh failed" "$home/stderr.log" "an unverifiable refresh must warn"
  assert_grep "no project" "$home/stderr.log" "the warning must say the CLI named no project"
  pass "fm-graph-reindex.sh: a response naming no project is a failure, not a silent success"
}

test_non_indexed_status_fails_with_its_hint() {
  local home repo out code
  read -r home repo <<<"$(new_case)"
  fm_graph_stub_projects "$home/projects.json" erroring-proj "$repo"
  out=$(FM_STUB_PROJECTS="$home/projects.json" FM_STUB_INDEX_STATUS=error \
    run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "a non-indexed status must not fail the caller"
  [ -z "$out" ] || fail "a non-indexed status must not claim success, got: $out"
  assert_grep "status='error'" "$home/stderr.log" "the warning must report the status it got back"
  pass "fm-graph-reindex.sh: a non-indexed status is a named failure"
}

# A payload that cannot be read is a broken graph, not an unindexed project - the
# same distinction test_lookup_error_is_non_fatal_and_named pins for a hard error.
test_garbage_payload_is_non_fatal() {
  local home repo out code
  read -r home repo <<<"$(new_case)"
  printf 'not json at all\n' > "$home/projects.json"
  out=$(FM_STUB_PROJECTS="$home/projects.json" run_reindex "$home" "$repo"); code=$?
  expect_code 0 "$code" "an unparseable payload must not fail the caller"
  assert_grep "could not read the graph's project list" "$home/stderr.log" \
    "an unparseable payload must warn on stderr"
  assert_grep "no JSON payload" "$home/stderr.log" "the warning must say the payload was unreadable"
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
  fm_graph_stub_projects "$home/projects.json" "$(derived_for "$repo")" "$repo"
  printf '# comment\nfast\n' > "$home/config/graph-reindex-mode"
  FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$log" run_reindex "$home" "$repo" >/dev/null
  assert_grep '"mode":"fast"' "$log" "config/graph-reindex-mode must select the index mode"
  pass "fm-graph-reindex.sh: config/graph-reindex-mode selects the mode"
}

test_env_overrides_config_mode() {
  local home repo log
  read -r home repo <<<"$(new_case)"
  log="$home/calls.log"
  fm_graph_stub_projects "$home/projects.json" "$(derived_for "$repo")" "$repo"
  printf 'fast\n' > "$home/config/graph-reindex-mode"
  FM_GRAPH_REINDEX_MODE=moderate FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$log" \
    run_reindex "$home" "$repo" >/dev/null
  assert_grep '"mode":"moderate"' "$log" "FM_GRAPH_REINDEX_MODE must override the config file"
  pass "fm-graph-reindex.sh: FM_GRAPH_REINDEX_MODE overrides the config file"
}

test_unknown_mode_falls_back_to_full() {
  local home repo log
  read -r home repo <<<"$(new_case)"
  log="$home/calls.log"
  fm_graph_stub_projects "$home/projects.json" "$(derived_for "$repo")" "$repo"
  printf 'sideways\n' > "$home/config/graph-reindex-mode"
  FM_STUB_PROJECTS="$home/projects.json" FM_STUB_LOG="$log" run_reindex "$home" "$repo" >/dev/null
  assert_grep '"mode":"full"' "$log" "an unknown mode must fall back to full"
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

# --- against the real binary ------------------------------------------------
#
# Everything above this line runs against a stub, and a stub is a copy of our
# BELIEF about the CLI. The 2026-08-09 breakage was precisely that belief going out
# of date, so it could not have been caught by any number of stub assertions. These
# two drive the installed binary for real and skip cleanly when it is absent.
#
# CBM_CACHE_DIR points the binary's graph database at a throwaway dir under the
# test's temp root, so a test run never adds, refreshes, or deletes an entry in the
# graph the user actually works from. That isolation is the entire case for driving
# the installed binary here, so test_real_cli_refreshes_an_indexed_project ASSERTS
# it rather than recording it as verified once: a belief about a binary is exactly
# what went stale on 2026-08-09. Mode is fast because these fixtures are one file
# each and the mode knob is already pinned against the stub.

# real_cli: echo the installed codebase-memory binary, or return 1.
real_cli() {
  if [ -n "${FM_GRAPH_REAL_CLI:-}" ]; then
    [ -x "$FM_GRAPH_REAL_CLI" ] || return 1
    printf '%s\n' "$FM_GRAPH_REAL_CLI"
  elif command -v codebase-memory-mcp >/dev/null 2>&1; then
    command -v codebase-memory-mcp
  elif [ -x "$HOME/.local/bin/codebase-memory-mcp" ]; then
    printf '%s\n' "$HOME/.local/bin/codebase-memory-mcp"
  else
    return 1
  fi
}

# real_roots <cli> <cache>: the root_path of every project the graph under <cache>
# holds, one per line. Leading non-JSON output is dropped the same way
# fm_graph_call drops it, because the real binary is chatty on stdout too.
real_roots() {
  CBM_CACHE_DIR="$2" "$1" cli list_projects 2>/dev/null \
    | awk '/^[[:space:]]*[{[]/ { found = 1 } found { print }' \
    | jq -r '.projects[]?.root_path // empty' 2>/dev/null
}

# real_case: fresh home whose project dir holds a SPACE, plus its own graph cache.
# Echoes "<home>\t<repo>\t<cache>". The space is deliberate: it makes the real
# binary the judge of whether the argument survived, rather than our own jq
# round-trip. TAB-separated, and read back with IFS=$'\t', because the whole point
# of the fixture is a path that a space-separated handoff would tear in half.
real_case() {
  local home repo
  home=$(mktemp -d "$TMP_ROOT/real.XXXXXX")
  repo="$home/projects/a real proj"
  mkdir -p "$repo" "$home/config" "$home/cache" "$home/elsewhere-cache"
  fm_git_init_commit "$repo"
  printf 'def widget():\n    return 1\n' > "$repo/widget.py"
  git -C "$repo" add widget.py
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm add-widget
  printf '%s\t%s\t%s\n' "$home" "$repo" "$home/cache"
}

# The whole path end to end: index once (the opt-in a real project gets by hand),
# then let fm-graph-reindex.sh find and refresh it exactly as a merge would.
test_real_cli_refreshes_an_indexed_project() {
  local cli home repo cache out args
  if ! cli=$(real_cli); then
    pass "SKIP (codebase-memory-mcp not installed): real-CLI refresh"
    return 0
  fi
  IFS=$'\t' read -r home repo cache <<<"$(real_case)"
  args=$(jq -nc --arg repo_path "$repo" '{repo_path: $repo_path, mode: "fast", persistence: false}')
  if ! CBM_CACHE_DIR="$cache" "$cli" cli index_repository "$args" >/dev/null 2>"$home/index.log"; then
    fail "the real CLI could not index the fixture repo: $(tail -3 "$home/index.log")"
  fi
  out=$(CBM_CACHE_DIR="$cache" FM_GRAPH_REINDEX_MODE=fast FM_GRAPH_REINDEX_TIMEOUT_SECS=120 FM_GRAPH_LOOKUP_TIMEOUT_SECS=120 \
    FM_GRAPH_CLI_OVERRIDE="$cli" run_reindex "$home" "$repo")
  assert_contains "$out" "graph refreshed" \
    "the real CLI must accept what fm-graph-lib.sh builds$(printf '\n--- stderr ---\n')$(cat "$home/stderr.log")"
  assert_not_contains "$out" "nodes=unknown" "a real refresh must report the node count it got back"
  assert_no_grep "graph refresh failed" "$home/stderr.log" "a real refresh must not warn"
  # The isolation this case rests on, asserted rather than believed. A second, empty
  # cache must not see what the first indexed: if CBM_CACHE_DIR were ever ignored,
  # both reads would hit the ONE graph the user actually works from - which would by
  # then hold this throwaway fixture under a path that is about to be deleted - and
  # the suite would go on reporting green while quietly littering it, once per run.
  # Both halves matter: the positive read proves the check is not vacuously passing
  # on a binary that reports nothing at all.
  assert_contains "$(real_roots "$cli" "$cache")" "$repo" \
    "the isolated cache must hold the fixture this case just indexed"
  assert_not_contains "$(real_roots "$cli" "$home/elsewhere-cache")" "$repo" \
    "CBM_CACHE_DIR must isolate the graph; a fresh cache seeing the fixture means test runs write to the user's own graph"
  pass "fm-graph-lib.sh: the real codebase-memory CLI accepts the invocation we build"
}

# real_project_field <cli> <cache> <name> <field>: one field of the named project in
# the graph under <cache>, or empty. Same leading-non-JSON tolerance as real_roots.
real_project_field() {
  CBM_CACHE_DIR="$2" "$1" cli list_projects 2>/dev/null \
    | awk '/^[[:space:]]*[{[]/ { found = 1 } found { print }' \
    | jq -r --arg n "$3" --arg f "$4" '.projects[]? | select(.name == $n) | .[$f] // empty' 2>/dev/null
}

# The fix's whole premise, put to the real binary: that `name` addresses the recorded
# entry. It is a belief about an external surface, which is the exact species of thing
# that went stale on 2026-08-09, so the stub is not allowed to be its only witness.
# The fixture is the live defect in miniature - an entry named something the binary
# would never slug out of its clone path - and a green line is not enough to pass:
# the recorded entry's node count must MOVE, and no slug entry may appear beside it.
test_real_cli_addresses_the_recorded_short_name() {
  local cli home repo cache out args before after slug
  if ! cli=$(real_cli); then
    pass "SKIP (codebase-memory-mcp not installed): real-CLI addressing by recorded name"
    return 0
  fi
  IFS=$'\t' read -r home repo cache <<<"$(real_case)"
  slug=$(fm_graph_derived_name "$(cd "$repo" && pwd -P)")
  args=$(jq -nc --arg r "$repo" '{repo_path: $r, name: "shortproj", mode: "fast", persistence: false}')
  CBM_CACHE_DIR="$cache" "$cli" cli index_repository "$args" >/dev/null 2>"$home/index.log" \
    || fail "the real CLI could not seed the fixture: $(tail -3 "$home/index.log")"
  before=$(real_project_field "$cli" "$cache" shortproj nodes)
  [ -n "$before" ] || fail "the fixture must record a 'shortproj' entry to refresh"
  # Grow the repo, so a refresh that reached the entry shows as a node count that
  # moved - a green line alone proves nothing about which entry was written.
  printf 'def gadget():\n    return 2\n\n\ndef doohickey():\n    return 3\n' > "$repo/gadget.py"
  git -C "$repo" add gadget.py
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm add-gadget
  out=$(CBM_CACHE_DIR="$cache" FM_GRAPH_REINDEX_MODE=fast FM_GRAPH_REINDEX_TIMEOUT_SECS=120 FM_GRAPH_LOOKUP_TIMEOUT_SECS=120 \
    FM_GRAPH_CLI_OVERRIDE="$cli" run_reindex "$home" "$repo")
  assert_contains "$out" "project=shortproj" \
    "the real CLI must honour the recorded name$(printf '\n--- stderr ---\n')$(cat "$home/stderr.log")"
  after=$(real_project_field "$cli" "$cache" shortproj nodes)
  [ -n "$after" ] && [ "$after" != "$before" ] \
    || fail "the recorded entry must actually have been rewritten; nodes stayed at ${before:-none}"
  # Asked for by `name`, not by a field an entry might lack: a missing `nodes` would
  # otherwise read as a missing entry and pass this vacuously.
  [ -z "$(real_project_field "$cli" "$cache" "$slug" name)" ] \
    || fail "the refresh must not create a second, path-derived entry '$slug' beside the recorded one"
  pass "fm-graph-lib.sh: the real CLI refreshes the entry the graph records, not the path slug"
}

# This case replaces one that asserted the binary rejects the flag form, which was
# true of 0.8.1 and is not of 0.9.0. What generalizes is not any one shape but the
# EXPIRY DATE: a claim to have verified an external surface is only as good as the
# version it was verified against, so that is what is pinned. Going red on a binary
# update is the intended behavior - the fix is to re-verify and update the record,
# which docs/graph-cli-backend.md's last section spells out. CI installs no
# codebase-memory binary, so this skips there and bites only where re-verifying is
# actually possible.
test_real_cli_version_matches_the_verified_record() {
  local cli recorded actual header
  if ! cli=$(real_cli); then
    pass "SKIP (codebase-memory-mcp not installed): real-CLI version against the record"
    return 0
  fi
  # Anchored to the "Verified ... against" line, not to the first bold mention: the
  # doc keeps superseded records, and one added above this line would silently pin
  # the suite to a version nobody verified.
  recorded=$(sed -n 's/^Verified .* against \*\*codebase-memory-mcp \([0-9][0-9.]*\)\*\*.*/\1/p' \
    "$ROOT/docs/graph-cli-backend.md" | head -1)
  [ -n "$recorded" ] || fail "docs/graph-cli-backend.md must open its verified surface with 'Verified <date> against **codebase-memory-mcp <version>**'"
  actual=$("$cli" --version 2>/dev/null | sed -n 's/^codebase-memory-mcp \([0-9][0-9.]*\).*/\1/p' | head -1)
  [ -n "$actual" ] || fail "could not read a version out of '$cli --version'"
  [ "$actual" = "$recorded" ] || fail \
    "installed codebase-memory-mcp is $actual but docs/graph-cli-backend.md verified $recorded; re-derive the surface and update the record (see that file's last section)"
  # The lib header carries its own copy of the verified version, and a header that
  # drifts from the doc is how it came to assert a surface the binary did not have.
  header=$(sed -n 's/.*verified [0-9-]* against codebase-memory-mcp \([0-9][0-9.]*\).*/\1/p' \
    "$ROOT/bin/fm-graph-lib.sh" | head -1)
  [ "$header" = "$recorded" ] || fail \
    "bin/fm-graph-lib.sh's header verified '${header:-none}' but docs/graph-cli-backend.md verified $recorded; the two records must name one version"
  pass "fm-graph-lib.sh: the installed CLI is the version the backend record verified"
}

test_help_includes_entire_header
test_refreshes_indexed_project
test_arguments_are_one_json_object_not_flags
test_refresh_addresses_the_recorded_name
test_path_with_space_is_passed_intact
test_tolerates_non_json_leading_output
test_canonical_root_match_refreshes_the_recorded_entry
test_resolves_bare_project_name
test_note_error_is_silent_when_the_file_is_unwritable
test_unindexed_project_is_skipped_not_indexed
test_reindex_refuses_an_empty_name
test_missing_binary_is_non_fatal
test_missing_jq_is_non_fatal
test_missing_timeout_binary_is_non_fatal
test_lookup_error_is_non_fatal_and_named
test_index_error_is_non_fatal_and_names_its_cause
test_rejected_arguments_are_reported_verbatim
test_refresh_landing_on_another_project_fails_loudly
test_refresh_without_a_project_fails_loudly
test_non_indexed_status_fails_with_its_hint
test_garbage_payload_is_non_fatal
test_hung_cli_is_bounded
test_missing_directory_is_non_fatal
test_mode_from_config_file
test_env_overrides_config_mode
test_unknown_mode_falls_back_to_full
test_mode_off_disables_refresh
test_real_cli_refreshes_an_indexed_project
test_real_cli_addresses_the_recorded_short_name
test_real_cli_version_matches_the_verified_record
