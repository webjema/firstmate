#!/usr/bin/env bash
# fm-test.sh - the single owner of firstmate's test-run definition.
#
# The file set, the parallelism, the serial-only exceptions, the per-test timeout,
# and the output format live here and ONLY here, exactly as bin/fm-lint.sh owns the
# lint definition. Both gates invoke this script with no arguments:
#   - CI:       .github/workflows/ci.yml runs `bin/fm-test.sh`.
#   - Local:    a crewmate runs `bin/fm-test.sh` once before signalling review-ready.
# A local pass is therefore a CI pass, because they are the same run.
#
# WHY PARALLEL. The suite used to be a serial `for f in tests/*.test.sh` in CI and in
# every crew's habit. Individual tests take 0-63s while the whole serial suite took
# ~10 minutes and was still growing; one run was killed at a 600s tool ceiling, burning
# ten minutes for nothing. The suite is overwhelmingly wall-clock bound on sleeps and
# tmux settle time, not CPU, so its critical path is the SLOWEST TEST, not the sum.
# Running the file set through `xargs -P` collapses the sum to near that critical path.
#
# OUTPUT. A parallel suite whose failure you cannot attribute is worse than a slow
# serial one, so no test's output is ever interleaved with another's:
#   - each test's stdout+stderr is buffered to its own log file, never to the terminal;
#   - each test prints exactly ONE result line when it finishes (ok/FAIL/TIMEOUT + secs);
#   - at the end, every FAILING test's full buffered log is printed under a banner that
#     names its file, so a failure is always attributable to one test script.
#
# SERIAL-ONLY TESTS. FM_TEST_SERIAL_ONLY below lists tests that cannot share the box
# with a parallel phase; they run in a serial tail phase after it. That list is the one
# owner of "which tests are not parallel-safe" and states WHY per entry - an empty list
# is the goal, and a new entry needs a reason, not a shrug. Adding a flaky test to the
# list is a real fix; leaving it to fail randomly in the parallel phase is not.
#
# A per-test timeout (FM_TEST_TIMEOUT, default 300s) turns a hung test into one named,
# attributable TIMEOUT failure instead of a killed suite with nothing to show for it.
#
# Usage:
#   fm-test.sh                 run the canonical file set (what both gates run)
#   fm-test.sh <path>...       run only the given test files (developer convenience)
#   fm-test.sh --serial        run everything serially (bisecting a parallel-safety bug)
#   fm-test.sh --jobs <n>      override the parallel width (default: nproc)
#   fm-test.sh --list          print the canonical file set and exit
#
# Exit status is 0 only when every test passed.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The cwd the caller actually typed the paths against, captured BEFORE the cd below. The
# canonical file set is repo-relative, so the script runs from ROOT - but that silently
# invalidates every relative path the CALLER passed ("../tests/x.test.sh" from tests/),
# turning each one into a phantom failure for a test that is perfectly fine.
INVOCATION_PWD=$PWD
cd "$ROOT" || exit 1

# Tests that must NOT run in the parallel phase; they run in a serial tail after it.
# Each entry must state why, because an unexplained entry is indistinguishable from a test
# nobody bothered to fix. This is a QUARANTINE, not a resting place: an entry here is open
# debt, and serializing a test is containment, never a diagnosis.
#
# THE LIVE-PROCESS-RACE CLASS. Every entry below backgrounds a REAL long-running process -
# a watcher, a checkpoint, an away-daemon, a harness - and then asserts on WHEN it does
# something: it self-evicts, it releases its lock, it emits a wake within a poll interval,
# its text appears. Those assertions are races against the scheduler, and the parallel phase
# is the other runner in that race. With `nproc` workers saturating the box, a watcher on
# FM_POLL=0.2 does not get scheduled through its loop inside the window its test allows.
#
# Raising the bounds is NOT the fix, and I tried it twice. It does not remove the race, it
# only moves the line the race is lost at - and a slower bound still loses on a busier CI
# box, which is the one place a red gate costs the most. What removes the race is not making
# them compete: the serial tail runs them alone.
#
# This list was claimed to be safely empty twice. It was not. fm-watcher-lock failed 1 run in
# 3; once its bounds were widened, fm-watch-checkpoint failed 1 run in 6 - the same defect
# wearing a different test's name. Chasing the tests that happen to go red is how you stay one
# step behind a flake forever, so the list is instead derived from the HAZARD and populated by
# AUDITING EVERY TEST against it: a test belongs here if it backgrounds a live process and then
# bounded-waits on that process's behavior, whether or not it has ever failed yet. That audit
# is what found the last six - none of which had gone red at the time, and three of which
# (fm-daemon, fm-afk-launch, fm-backend-tmux-smoke) hold the tightest bounds in the suite.
# An intermittently-red merge gate is the single worst thing this script could ship, because it
# trains everyone to re-run until green, which is exactly how a real failure gets waved through.
#
#   fm-watcher-lock.test.sh - waits for a live watcher to self-evict after a lock takeover
#   fm-watch-checkpoint.test.sh - waits for the watcher child to release .watch.lock
#   fm-watch-triage.test.sh - asserts wake classification within bounded poll windows
#   fm-silent-holes.test.sh - waits on a live watcher for wakes that must NOT be absorbed
#   fm-wake-queue.test.sh - waits for a live watcher to enqueue durable wake records
#   fm-wake-payload.test.sh - waits for a live watcher to emit a fat wake payload
#   fm-wt-activity.test.sh - waits for the watcher's worktree-activity probe to settle
#   fm-turnend-body.test.sh - waits for a live watcher to publish a bodied turn-end marker
#   fm-wake-daemon-lifecycle-e2e.test.sh - waits on the away-daemon's watcher lifecycle
#   fm-afk-inject-e2e.test.sh - backgrounds a real supervise-daemon, then bounded-waits for
#     its pid file and for injected keystrokes to land in a pane
#   fm-secondmate-safety.test.sh - backgrounds a real fm-watch.sh (FM_POLL=1) and asserts it
#     is still live after a bounded wait, then that it emitted no stale wake
#   fm-pi-primary-live-e2e.test.sh - launches a real Pi harness and wait_for_text's on its
#     output with 40-60s bounds (a no-op 0s skip where Pi is absent, e.g. this box)
#   fm-afk-launch.test.sh - backgrounds the real launcher lifecycle and a TERM-trapping daemon
#     stand-in, then bounded-waits on each; its lock-initialization grace is ~1s wide, and its
#     own comments already record it going flaky the moment the suite went parallel
#   fm-daemon.test.sh - runs wedge notifiers under FM_WEDGE_ALARM_TIMEOUT_SECS=1 and asserts a
#     backgrounded descendant recorded its pid inside that 1s budget - the tightest bound here
#   fm-backend-tmux-smoke.test.sh - sends keys to a live tmux pane, then asserts on captured
#     output after fixed 0.3-0.6s sleeps, with no retry loop to absorb a starved pane shell
#   fm-pi-watch-extension.test.sh - the Pi plugin forks a detached arm child; the test bounded-
#     waits 5s for its pid file and 5s more for its TERM handler to log
#   fm-pool-warm.test.sh - backgrounds the real fm-pool-warm.sh and bounded-waits 3s for it to
#     take its flock and reach a lease
#   fm-turnend-guard.test.sh - asserts the guard hook completes in under 3s; a wall-clock
#     performance bound is starved by a saturated box exactly like a background-process race
#
# The cost is real, and stating it honestly is the point (measured on this 8-core box):
#   serial (the old CI loop)          421s
#   parallel, quarantine EMPTY        155s   <- and red about 1 run in 6
#   parallel + serial tail (this)     279s   <- 10 consecutive runs, 10 green
# Determinism costs ~124s over a flaky parallel suite and still beats serial by ~2.4 minutes. A
# suite that is fast and occasionally wrong is worth less than no suite at all, because it is
# believed. Shrinking this list means fixing a test so it no longer races a live process -
# not deleting the line and hoping.
#
# Unrelated, and stated because an earlier version of this comment got it wrong: NOT every test
# uses a private tmux server. tests/fm-afk-launch.test.sh creates sessions on the DEFAULT server
# ($$-keyed names, scoped cleanup, so not destructive) - that blanket claim was false, and it
# was the stated justification for this list being empty. State what is proven, not what is
# convenient.
FM_TEST_SERIAL_ONLY=${FM_TEST_SERIAL_ONLY:-"\
fm-watcher-lock.test.sh \
fm-watch-checkpoint.test.sh \
fm-watch-triage.test.sh \
fm-silent-holes.test.sh \
fm-wake-queue.test.sh \
fm-wake-payload.test.sh \
fm-wt-activity.test.sh \
fm-turnend-body.test.sh \
fm-wake-daemon-lifecycle-e2e.test.sh \
fm-afk-inject-e2e.test.sh \
fm-secondmate-safety.test.sh \
fm-pi-primary-live-e2e.test.sh \
fm-afk-launch.test.sh \
fm-daemon.test.sh \
fm-backend-tmux-smoke.test.sh \
fm-pi-watch-extension.test.sh \
fm-pool-warm.test.sh \
fm-turnend-guard.test.sh"}

JOBS=${FM_TEST_JOBS:-$(nproc 2>/dev/null || echo 4)}
TIMEOUT=${FM_TEST_TIMEOUT:-300}
MODE=parallel
FILES=()
# Internal worker state. Carried as FLAGS, never as exported environment: the worker
# runs the test as a child process, so anything it exports is inherited by the test -
# and a test that itself invokes fm-test.sh (tests/fm-test-runner.test.sh does) would
# silently be hijacked into worker mode. Flags stop at the process that parses them.
WORKER=0
RUNDIR=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,/^set -eu/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    --serial) MODE=serial; shift ;;
    --jobs) shift; [ "$#" -gt 0 ] || { echo "fm-test.sh: --jobs needs a number" >&2; exit 1; }; JOBS=$1; shift ;;
    --list) MODE=list; shift ;;
    --worker) WORKER=1; shift ;;
    --rundir) shift; [ "$#" -gt 0 ] || { echo "fm-test.sh: --rundir needs a path" >&2; exit 1; }; RUNDIR=$1; shift ;;
    --timeout) shift; [ "$#" -gt 0 ] || { echo "fm-test.sh: --timeout needs seconds" >&2; exit 1; }; TIMEOUT=$1; shift ;;
    --*) echo "fm-test.sh: unknown flag $1" >&2; exit 1 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

# The canonical file set: the ONE authoritative definition. Callers reference this
# script; they never re-spell this glob.
if [ "${#FILES[@]}" -eq 0 ]; then
  FILES=(tests/*.test.sh)
elif [ "$WORKER" = 0 ]; then
  # Re-anchor caller-supplied relative paths to the cwd they were typed against.
  #
  # RUNNER ONLY. A worker must use the path string the runner handed it, VERBATIM: the
  # per-test .rc/.log filenames are slugs of that string, and the runner aggregates on the
  # same string. Re-anchoring inside the worker rewrote "tests/x.test.sh" to an absolute
  # path, so the worker wrote its .rc under a slug the runner never looked for and EVERY
  # test came back "never reported" - 58 of 58 red. It failed closed, which is why the
  # 10-run gate caught it instead of a user, but the slug is a contract between the two
  # halves of this script and only one half may normalize it.
  for i in "${!FILES[@]}"; do
    case "${FILES[i]}" in
      /*) ;;
      *) [ -e "$INVOCATION_PWD/${FILES[i]}" ] && FILES[i]="$INVOCATION_PWD/${FILES[i]}" ;;
    esac
  done
fi

if [ "$MODE" = list ]; then
  printf '%s\n' "${FILES[@]}"
  exit 0
fi

command -v timeout >/dev/null 2>&1 || { echo "fm-test.sh: coreutils 'timeout' is required" >&2; exit 127; }

# The worker. Buffers the test's whole output to its own log and prints exactly one
# result line, so two concurrent tests can never interleave their output. Invoked as a
# subprocess by xargs (and directly in the serial phase), so it is spelled as a
# re-entrant call to this script rather than a shell function - which is also why it
# sits before the run directory is created: a worker is given the runner's, and must
# not mint (or clean up) one of its own.
if [ "$WORKER" = 1 ]; then
  [ -n "$RUNDIR" ] || { echo "fm-test.sh: --worker needs --rundir" >&2; exit 1; }
  test_file=${FILES[0]}
  slug=$(printf '%s' "$test_file" | tr '/' '_')
  log="$RUNDIR/$slug.log"
  start=$(date +%s)
  rc=0
  timeout --kill-after=10s "${TIMEOUT}s" bash "$test_file" > "$log" 2>&1 || rc=$?
  secs=$(( $(date +%s) - start ))
  printf '%s\n' "$rc" > "$RUNDIR/$slug.rc"
  if [ "$rc" -eq 0 ]; then
    printf 'ok    %4ss  %s\n' "$secs" "$test_file"
  elif [ "$rc" -eq 124 ] || { [ "$rc" -eq 137 ] && [ "$secs" -ge "$TIMEOUT" ]; }; then
    # 124 is timeout's own verdict. 137 is ANY SIGKILL - including the OOM killer, which
    # parallelism makes MORE likely, not less - so it only means TIMEOUT if the test
    # actually ran out its clock. A test killed at 0s is not a slow test, and sending the
    # reader after a nonexistent timeout wastes exactly the time this script saves.
    printf 'TIMEOUT %2ss  %s (exceeded %ss)\n' "$secs" "$test_file" "$TIMEOUT"
  else
    printf 'FAIL  %4ss  %s (exit %s)\n' "$secs" "$test_file" "$rc"
  fi
  exit 0
fi

RUNDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-test.XXXXXX")
trap 'rm -rf "$RUNDIR"' EXIT
# "$ROOT/bin/fm-test.sh", never "$0": line 45 already cd'd to ROOT, so a relative $0
# ("../bin/fm-test.sh" from tests/) no longer resolves and EVERY worker becomes a phantom
# failure. It fails closed, but it fails for a reason that has nothing to do with the tests.
WORKER_CMD=("$ROOT/bin/fm-test.sh" --worker --rundir "$RUNDIR" --timeout "$TIMEOUT")

# Split the file set into a parallel phase and a serial tail phase.
PARALLEL=()
SERIAL=()
for f in "${FILES[@]}"; do
  name=$(basename "$f")
  case " $FM_TEST_SERIAL_ONLY " in
    *" $name "*) SERIAL+=("$f") ;;
    *) PARALLEL+=("$f") ;;
  esac
done
if [ "$MODE" = serial ]; then
  SERIAL=(${PARALLEL[@]+"${PARALLEL[@]}"} ${SERIAL[@]+"${SERIAL[@]}"})
  PARALLEL=()
  JOBS=1
fi

# NUL-delimited, so a test path containing a space (or a quote, which xargs would
# otherwise interpret) reaches the worker whole instead of being split into two
# nonexistent files.
#
# The dispatch status is deliberately IGNORED: xargs exits 123 if any worker exits
# non-zero, and under `set -e` that would abort the runner before it printed a single
# failing log. The .rc files written by the workers are the only source of truth for
# what passed - a test whose .rc is missing is counted as a failure below, so a worker
# that dies without reporting is caught rather than silently skipped.
SUITE_START=$(date +%s)
if [ "${#PARALLEL[@]}" -gt 0 ]; then
  printf 'fm-test.sh: %s tests, %s at a time (timeout %ss each)\n' \
    "${#PARALLEL[@]}" "$JOBS" "$TIMEOUT"
  printf '%s\0' "${PARALLEL[@]}" | xargs -0 -P "$JOBS" -n 1 "${WORKER_CMD[@]}" || true
fi
if [ "${#SERIAL[@]}" -gt 0 ]; then
  [ "$MODE" = serial ] || printf 'fm-test.sh: %s serial-only tests\n' "${#SERIAL[@]}"
  for f in "${SERIAL[@]}"; do
    "${WORKER_CMD[@]}" "$f" || true
  done
fi
SUITE_SECS=$(( $(date +%s) - SUITE_START ))

# Aggregate. A test whose .rc file is missing never reported - treat that as a failure
# rather than silently passing a test that did not run.
failed=()
for f in ${PARALLEL[@]+"${PARALLEL[@]}"} ${SERIAL[@]+"${SERIAL[@]}"}; do
  slug=$(printf '%s' "$f" | tr '/' '_')
  rc=$(cat "$RUNDIR/$slug.rc" 2>/dev/null || echo missing)
  [ "$rc" = 0 ] || failed+=("$f")
done

total=$(( ${#PARALLEL[@]} + ${#SERIAL[@]} ))
if [ "${#failed[@]}" -gt 0 ]; then
  for f in "${failed[@]}"; do
    slug=$(printf '%s' "$f" | tr '/' '_')
    printf '\n===== FAIL: %s =====\n' "$f"
    cat "$RUNDIR/$slug.log" 2>/dev/null || echo "(no output captured: the test never reported)"
  done
  printf '\nfm-test.sh: %s of %s tests FAILED in %ss:\n' "${#failed[@]}" "$total" "$SUITE_SECS"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi

printf '\nfm-test.sh: %s tests passed in %ss\n' "$total" "$SUITE_SECS"
