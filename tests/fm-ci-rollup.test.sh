#!/usr/bin/env bash
# Tests for bin/fm-ci-rollup-lib.sh: the single-owner PR CI-rollup verdict shared by
# the merge/CI poll (fm-pr-check.sh) and the never-merge-a-red-PR gate
# (fm-pr-merge.sh).
#
# The jq verdict expression itself runs inside gh's embedded -q and is exercised
# end-to-end through both callers' suites (which stub gh's line output). Here we pin
# the library seam: fm_ci_rollup_line returns the gh line when gh is present, and
# returns NOTHING on a tool error so no caller ever reads a red verdict out of a
# broken gh - the same "never act on a tool error" rule the poll follows.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-ci-rollup-lib.sh
. "$ROOT/bin/fm-ci-rollup-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ci-rollup-tests)

test_query_is_defined() {
  [ -n "$FM_CI_ROLLUP_QUERY" ] || fail "FM_CI_ROLLUP_QUERY must be defined by the lib"
  case "$FM_CI_ROLLUP_QUERY" in
    *statusCheckRollup*) : ;;
    *) fail "FM_CI_ROLLUP_QUERY must reduce statusCheckRollup" ;;
  esac
  pass "the lib defines the shared rollup query"
}

test_returns_gh_line_when_present() {
  local dir fakebin out
  dir="$TMP_ROOT/gh-present"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
# A gh stub: whatever the -q query is, echo a canned rollup line.
printf 'OPEN abc123 pass\n'
SH
  chmod +x "$fakebin/gh"
  out=$(PATH="$fakebin:$PATH" fm_ci_rollup_line https://github.com/example/repo/pull/1)
  [ "$out" = "OPEN abc123 pass" ] || fail "fm_ci_rollup_line should return the gh line, got '$out'"
  pass "fm_ci_rollup_line returns the gh rollup line when gh is present"
}

test_returns_nothing_when_gh_absent() {
  local dir emptybin out
  dir="$TMP_ROOT/gh-absent"
  emptybin="$dir/emptybin"
  mkdir -p "$emptybin"
  # A PATH with no gh at all: the lib must degrade to empty, never error out.
  out=$(PATH="$emptybin" fm_ci_rollup_line https://github.com/example/repo/pull/1) \
    || fail "fm_ci_rollup_line must not fail when gh is absent"
  [ -z "$out" ] || fail "fm_ci_rollup_line should return nothing when gh is absent, got '$out'"
  pass "fm_ci_rollup_line returns nothing (no error) when gh is absent"
}

test_returns_nothing_on_gh_error() {
  local dir fakebin out
  dir="$TMP_ROOT/gh-error"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh: some API error" >&2
exit 1
SH
  chmod +x "$fakebin/gh"
  out=$(PATH="$fakebin:$PATH" fm_ci_rollup_line https://github.com/example/repo/pull/1) \
    || fail "fm_ci_rollup_line must swallow a gh error, not propagate it"
  [ -z "$out" ] || fail "fm_ci_rollup_line should return nothing on a gh error, got '$out'"
  pass "fm_ci_rollup_line returns nothing on a gh error"
}

test_query_is_defined
test_returns_gh_line_when_present
test_returns_nothing_when_gh_absent
test_returns_nothing_on_gh_error
