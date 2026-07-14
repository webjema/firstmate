#!/usr/bin/env bash
# Tests for bin/fm-test.sh, the single owner of the test-run definition.
#
# The suite is what every crew and CI run trusts, so the runner has to be trustworthy
# before the suite is. Four properties, each of which has a failure mode that is WORSE
# than a slow serial run:
#
#   1. It runs tests concurrently. (Otherwise the whole change is a no-op.)
#   2. A failing test is named unambiguously and its output is NOT interleaved with any
#      other test's. A parallel suite whose failure you cannot attribute is worse than a
#      slow serial one.
#   3. A hung test becomes one attributable TIMEOUT failure, not a killed suite.
#   4. A green exit means every test actually ran and reported. A runner that loses a
#      test's result and exits 0 is the worst outcome available.
#
# Plus the parity contract that makes a local pass a CI pass: CI must invoke this exact
# script and re-spell nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FM_TEST="$ROOT/bin/fm-test.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-runner-tests)

# A throwaway suite of fake tests. They are NOT run from tests/ - the runner under test
# would otherwise recurse into the real suite.
make_suite() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

write_test() {  # <dir> <name> <body>
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/$2"
  chmod +x "$1/$2"
}

# The runner resolves its own file set from the repo root, so a fake suite must be
# handed to it as absolute paths. Bare "<name>.test.sh" arguments are expanded against
# <dir>; flags pass through untouched.
#
# Sets two GLOBALS rather than printing: the runner's exit status is half of what is
# under test here, and a `$(...)` capture would run this in a subshell and lose it.
FM_TEST_RC=0
FM_TEST_OUT=""
run_fm_test() {  # <dir> <args...> -> FM_TEST_OUT, FM_TEST_RC
  local dir=$1 a
  shift
  local args=()
  for a in "$@"; do
    case "$a" in
      *.test.sh) args+=("$dir/$a") ;;
      *) args+=("$a") ;;
    esac
  done
  set +e
  FM_TEST_OUT=$("$FM_TEST" "${args[@]}" 2>&1)
  FM_TEST_RC=$?
  set -e
}

test_runs_tests_concurrently() {
  local dir out
  dir=$(make_suite concurrent)
  # Four tests that each sleep 3s. Serially that is >= 12s; concurrently it is ~3s.
  # The assertion is on the runner's own reported wall-clock, so it cannot pass by
  # accident on a fast box.
  local i
  for i in 1 2 3 4; do
    write_test "$dir" "sleeper$i.test.sh" 'sleep 3; echo "slept"'
  done

  run_fm_test "$dir" --jobs 4 sleeper1.test.sh sleeper2.test.sh sleeper3.test.sh sleeper4.test.sh
  out=$FM_TEST_OUT
  expect_code 0 "$FM_TEST_RC" "concurrent: four sleeping tests should all pass"

  local secs
  secs=$(printf '%s\n' "$out" | sed -n 's/^fm-test.sh: 4 tests passed in \([0-9]*\)s$/\1/p')
  [ -n "$secs" ] || fail "concurrent: runner did not print a total-time summary"$'\n'"$out"
  # 4x3s serial = 12s. Anything under 8s proves they overlapped, with generous slack
  # for a loaded box.
  [ "$secs" -lt 8 ] \
    || fail "concurrent: 4x3s tests took ${secs}s - they ran serially, not in parallel"
  pass "fm-test.sh runs the file set concurrently (4x3s tests in ${secs}s)"
}

test_failure_is_attributable_and_not_interleaved() {
  local dir out
  dir=$(make_suite failure)
  # A failing test whose output is many lines, racing a passing test that prints its own
  # many lines. If the runner streamed both, the failing test's lines would be split by
  # the passing test's. Buffering per test is what keeps a failure readable.
  # The single quotes are the point: these are fake test BODIES, expanded when the runner
  # executes them, never by this test file.
  # shellcheck disable=SC2016 # deliberate: the body is a script, not a string to expand here
  write_test "$dir" "boom.test.sh" \
    'for i in $(seq 1 20); do echo "BOOM-LINE-$i"; sleep 0.02; done; echo "not ok - the boom" >&2; exit 3'
  # shellcheck disable=SC2016 # deliberate: the body is a script, not a string to expand here
  write_test "$dir" "noisy.test.sh" \
    'for i in $(seq 1 20); do echo "NOISE-LINE-$i"; sleep 0.02; done; exit 0'

  run_fm_test "$dir" --jobs 2 boom.test.sh noisy.test.sh
  out=$FM_TEST_OUT
  expect_code 1 "$FM_TEST_RC" "failure: the suite must exit non-zero when a test fails"

  assert_contains "$out" 'FAIL' "failure: the failing test must be marked FAIL"
  assert_contains "$out" "===== FAIL: $dir/boom.test.sh =====" \
    "failure: the failing test's output must be printed under a banner naming its file"
  assert_contains "$out" 'not ok - the boom' \
    "failure: the failing test's stderr must survive to the report"
  assert_contains "$out" '1 of 2 tests FAILED' "failure: the summary must count the failures"

  # The failing test's buffered block must be contiguous: no line of the OTHER test may
  # appear between its first and last line. This is the anti-interleave assertion.
  local block
  block=$(printf '%s\n' "$out" | sed -n "/===== FAIL: .*boom.test.sh =====/,\$p")
  assert_contains "$block" 'BOOM-LINE-1' "failure: the failing test's block lost its first line"
  assert_contains "$block" 'BOOM-LINE-20' "failure: the failing test's block lost its last line"
  assert_not_contains "$block" 'NOISE-LINE' \
    "failure: another test's output interleaved into the failing test's block"
  pass "a failing test is named, its output is buffered whole, and nothing interleaves into it"
}

test_hung_test_times_out_and_is_named() {
  local dir out
  dir=$(make_suite timeout)
  write_test "$dir" "hang.test.sh" 'sleep 60'
  write_test "$dir" "quick.test.sh" 'echo fine'

  FM_TEST_TIMEOUT=2 run_fm_test "$dir" --jobs 2 hang.test.sh quick.test.sh
  out=$FM_TEST_OUT
  expect_code 1 "$FM_TEST_RC" "timeout: a hung test must fail the suite"
  assert_contains "$out" 'TIMEOUT' "timeout: a hung test must be reported as a TIMEOUT"
  assert_contains "$out" 'hang.test.sh' "timeout: the timed-out test must be named"
  assert_contains "$out" 'ok' "timeout: the healthy test must still have passed"
  pass "a hung test becomes one named TIMEOUT failure instead of a killed suite"
}

test_serial_only_list_runs_in_a_tail_phase() {
  local dir out
  dir=$(make_suite serial-only)
  write_test "$dir" "para.test.sh" 'echo p'
  write_test "$dir" "lonely.test.sh" 'echo l'

  FM_TEST_SERIAL_ONLY=lonely.test.sh run_fm_test "$dir" --jobs 4 para.test.sh lonely.test.sh
  out=$FM_TEST_OUT
  expect_code 0 "$FM_TEST_RC" "serial-only: both tests should pass"
  assert_contains "$out" '1 tests, 4 at a time' "serial-only: the parallel phase must exclude the serial test"
  assert_contains "$out" '1 serial-only tests' "serial-only: the serial tail phase must announce itself"
  assert_contains "$out" '2 tests passed' "serial-only: both phases must be counted in the total"
  pass "a serial-only test is held out of the parallel phase and run in a serial tail"
}

test_serial_mode_still_runs_everything() {
  local dir out
  dir=$(make_suite serial-mode)
  write_test "$dir" "a.test.sh" 'echo a'
  write_test "$dir" "b.test.sh" 'exit 1'

  run_fm_test "$dir" --serial a.test.sh b.test.sh
  out=$FM_TEST_OUT
  expect_code 1 "$FM_TEST_RC" "serial: a failing test must still fail the suite"
  # Every test runs even after a failure - one broken script never hides the rest.
  assert_contains "$out" 'a.test.sh' "serial: the passing test must still have run"
  assert_contains "$out" '1 of 2 tests FAILED' "serial: the summary must count both tests"
  pass "--serial runs the whole file set and still reports every test"
}

test_a_test_may_itself_invoke_the_runner() {
  local dir out
  dir=$(make_suite nested)
  # THIS test file is itself run BY the runner in the real suite, so the runner's
  # internal worker state must not reach the test process. It used to be exported
  # (FM_TEST_WORKER=1), which the test inherited as a child process - so the runner
  # this test invoked silently acted as a WORKER, ran one file, and printed no summary.
  # The worker protocol is flags now, and flags stop at the process that parses them.
  write_test "$dir" "inner.test.sh" 'echo inner ran'
  write_test "$dir" "outer.test.sh" \
    "$FM_TEST '$dir/inner.test.sh' | grep -q '1 tests passed' || { echo 'nested runner did not behave as a runner'; exit 1; }"

  run_fm_test "$dir" --jobs 2 outer.test.sh
  out=$FM_TEST_OUT
  expect_code 0 "$FM_TEST_RC" \
    "nested: a test run BY the runner must be able to invoke the runner itself"$'\n'"$out"
  pass "the runner's worker state never leaks into the test process (a test can invoke it)"
}

test_a_lost_worker_is_reported_not_silently_skipped() {
  local dir out
  dir=$(make_suite lost-worker)
  # A worker that is KILLED never writes its .rc. The runner must call that a failure,
  # not exit green having quietly skipped a test. (xargs also exits 123 when any worker
  # exits non-zero, which under `set -e` used to abort the runner before it printed a
  # single log - so this pins both halves: the run completes, and the loss is reported.)
  write_test "$dir" "suicide.test.sh" 'kill -9 $$'
  write_test "$dir" "fine.test.sh" 'echo fine'

  run_fm_test "$dir" --jobs 2 suicide.test.sh fine.test.sh
  out=$FM_TEST_OUT
  expect_code 1 "$FM_TEST_RC" "lost-worker: a test that never reported must fail the suite"
  assert_contains "$out" 'suicide.test.sh' "lost-worker: the lost test must be named"
  assert_contains "$out" 'FAILED' "lost-worker: the summary must report the failure"
  assert_contains "$out" 'ok' "lost-worker: the healthy test must still have run and passed"
  pass "a worker that dies without reporting is counted as a failure, not skipped"
}

test_path_with_a_space_is_not_split() {
  local dir out
  dir=$(make_suite space-path)
  # The dispatch is NUL-delimited. Whitespace-delimited xargs would split this into two
  # nonexistent files and report a confusing failure for a test that is actually fine.
  write_test "$dir" "a b.test.sh" 'echo spaced'

  run_fm_test "$dir" "a b.test.sh"
  out=$FM_TEST_OUT
  expect_code 0 "$FM_TEST_RC" "space-path: a test whose path contains a space must run"$'\n'"$out"
  assert_contains "$out" '1 tests passed' "space-path: the spaced test must be counted once"
  pass "a test path containing a space reaches the worker whole"
}

test_quarantined_tests_are_declared_with_a_reason() {
  local src quarantined name count
  local -a names
  src=$(cat "$FM_TEST")
  # The quarantine is real debt, so it must be visible. Every name in the default
  # FM_TEST_SERIAL_ONLY has to be a test that exists and has to be explained in the
  # comment block above it - an entry nobody can justify is an entry nobody will remove.
  # Read the DEFAULT list out of the script's own source, so an env override in this
  # test's environment cannot mask what the repo actually ships.
  #
  # Parse the WHOLE assignment, not one line of it. The previous version anchored a sed to
  # `^FM_TEST_SERIAL_ONLY=...}$` - a single-line match - so the moment the list grew past one
  # line and wrapped with backslash continuations, it extracted NOTHING, the loop below never
  # iterated, and this test passed while checking zero entries. It stayed green with a
  # deliberately-injected `THIS-TEST-DOES-NOT-EXIST.test.sh` in the list. A gate that cannot
  # fail is not a gate, so the emptiness guard below is the load-bearing part of this test:
  # it is what makes a parse regression fail loudly instead of silently passing everything.
  quarantined=$(sed -n '/^FM_TEST_SERIAL_ONLY=/,/}$/p' "$FM_TEST" \
    | sed 's/^FM_TEST_SERIAL_ONLY=[^"]*"\{0,1\}//; s/"\{0,1\}}[[:space:]]*$//; s/\\[[:space:]]*$//')
  # Split on whitespace deliberately - the list is whitespace-separated, and an array makes
  # that intent explicit rather than leaning on an unquoted expansion.
  read -ra names <<<"$(printf '%s' "$quarantined" | tr '\n' ' ')"
  count=${#names[@]}
  [ "$count" -gt 0 ] || fail "quarantine parse extracted 0 entries - the list format changed and this gate went blind"

  for name in "${names[@]}"; do
    assert_present "$ROOT/tests/$name" "quarantined test $name does not exist"
    assert_contains "$src" "#   $name -" \
      "quarantined test $name has no stated reason in bin/fm-test.sh"
  done
  pass "all $count serial-only quarantined tests exist and state why they are quarantined"
}

test_runs_from_a_non_root_cwd() {
  local dir out
  dir=$(make_suite non-root-cwd)
  write_test "$dir" "fine.test.sh" 'echo fine'

  # The runner cd's to the repo root, which used to invalidate BOTH the worker command
  # ($0, relative) and the caller's relative file paths - every test became a phantom
  # failure for a reason that had nothing to do with the test. Fails closed, so nothing was
  # ever silently passed; it just sent the reader hunting a bug that did not exist.
  set +e
  out=$( (cd "$ROOT/tests" && "../bin/fm-test.sh" "../bin/../tests/fm-lint.test.sh") 2>&1 )
  FM_TEST_RC=$?
  set -e
  expect_code 0 "$FM_TEST_RC" \
    "non-root cwd: a relative invocation from another directory must still run"$'\n'"$out"
  assert_contains "$out" '1 tests passed' "non-root cwd: the test did not actually run"
  assert_not_contains "$out" 'No such file' "non-root cwd: path was resolved against the wrong cwd"
  pass "the runner works from a non-root cwd (worker command and relative paths both resolve)"
}

test_a_sigkill_is_not_mislabelled_a_timeout() {
  local dir out
  dir=$(make_suite sigkill)
  # 137 is ANY SIGKILL, including the OOM killer - which parallelism makes MORE likely.
  # Reporting an instantly-killed test as "TIMEOUT (exceeded 300s)" sends the reader after
  # a timeout that never happened.
  write_test "$dir" "killed.test.sh" 'kill -9 $$'

  run_fm_test "$dir" --jobs 1 killed.test.sh
  out=$FM_TEST_OUT
  expect_code 1 "$FM_TEST_RC" "sigkill: a killed test must fail the suite"
  assert_contains "$out" 'killed.test.sh' "sigkill: the killed test must be named"
  assert_contains "$out" '(exit 137)' "sigkill: the kill signal must be reported on the result line"
  # Match the TIMEOUT label's own distinctive text, NOT the bare word: bash's job-control
  # message echoes the worker's command line verbatim - including the literal "${TIMEOUT}s"
  # - so grepping for "TIMEOUT" matches bash's noise and passes/fails for the wrong reason.
  assert_not_contains "$out" 'exceeded' \
    "sigkill: a test killed instantly is not a timeout - do not send the reader after one"
  pass "a SIGKILL that is not a timeout is reported as a failure, not a phantom timeout"
}

test_worker_reports_under_the_slug_the_runner_dispatched() {
  local rundir slug
  rundir=$(mktemp -d "$TMP_ROOT/rundir.XXXXXX")

  # The .rc/.log filename is a SLUG of the path string, and it is a contract between the
  # two halves of this script: the worker writes the result, the runner aggregates it, and
  # both must slug the SAME string. The default file set is repo-relative
  # ("tests/x.test.sh"), so a worker that normalizes its path to absolute writes its .rc
  # where the runner never looks - and every test comes back "never reported". That
  # regression was 58-of-58 red and could ONLY reproduce through the default glob, which
  # every other case here bypasses by passing absolute paths.
  ( cd "$ROOT" && ./bin/fm-test.sh --worker --rundir "$rundir" --timeout 60 tests/fm-lint.test.sh ) >/dev/null 2>&1

  slug='tests_fm-lint.test.sh'
  assert_present "$rundir/$slug.rc" \
    "the worker must report under the slug of the path the runner dispatched, not a rewritten one"
  [ "$(cat "$rundir/$slug.rc")" = 0 ] \
    || fail "worker slug: the test ran but its recorded exit code is wrong"
  pass "a worker reports under the slug of the exact path string it was given"
}

test_ci_invokes_this_script_and_respells_nothing() {
  local ci="$ROOT/.github/workflows/ci.yml"
  assert_grep 'bin/fm-test.sh' "$ci" \
    "CI must invoke bin/fm-test.sh, so a local pass is a CI pass"
  # The old hand-rolled loop must be gone: a second spelling of the file set is a second
  # owner of the test-run definition, and the two would drift.
  assert_no_grep 'for test_script in tests/*.test.sh' "$ci" \
    "CI must not re-spell the test loop; bin/fm-test.sh owns the file set"
  pass "CI runs the identical bin/fm-test.sh and re-spells no part of the definition"
}

test_runs_tests_concurrently
test_failure_is_attributable_and_not_interleaved
test_hung_test_times_out_and_is_named
test_serial_only_list_runs_in_a_tail_phase
test_serial_mode_still_runs_everything
test_a_test_may_itself_invoke_the_runner
test_a_lost_worker_is_reported_not_silently_skipped
test_path_with_a_space_is_not_split
test_quarantined_tests_are_declared_with_a_reason
test_runs_from_a_non_root_cwd
test_a_sigkill_is_not_mislabelled_a_timeout
test_worker_reports_under_the_slug_the_runner_dispatched
test_ci_invokes_this_script_and_respells_nothing
