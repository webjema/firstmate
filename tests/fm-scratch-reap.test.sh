#!/usr/bin/env bash
# Tests for bin/fm-scratch-reap.sh: the janitor that reclaims orphaned harness
# scratchpad session dirs.
#
# Load-bearing behaviors:
#   (a) a session dir untouched past the threshold is reaped; a fresh one is spared
#   (b) --protect and --self spare a dir regardless of age
#   (c) --dry-run deletes nothing
#   (d) the root must be a claude-<uid> scratch root, or the reaper refuses
#   (e) non-session siblings (bundled-skills/<version>) are never touched
#   (f) an emptied project-encoded parent dir is cleaned up
#   (g) a LIVE session survives a find that rejects the GNU-only primaries (BSD/macOS)
#   (h) a probe that cannot run spares the dir - the reaper fails CLOSED - and says so
#   (i) a per-directory traversal error spares that dir, names it, and keeps reaping
#       the dirs that DID answer - an unreadable subdir is not a broken probe
#   (j) ... but that sparing is not forever: past the hard ceiling it is reaped
#   (k) --max-age-hours 0 is refused, because -mmin -0 matches nothing and would
#       make every session dir, live ones included, read as dead
#   (l) a firstmate task temp root whose own mtime is stale but whose content was
#       just written survives the fm-* pass, while a truly dead one is reclaimed
#   (m) ... and so does one that nothing has written for days and no process has open,
#       but which a live process NAMES in its environment - the 2026-08-24 incident,
#       and the only rail that answers for it
#
# (g) and (h) are regression tests for a defect that deleted live sessions' scratch on
# every macOS run, so neither may be satisfied by a GNU-only path: both drive the
# reaper through a stub `find` and assert the outcome on the implementation the
# platform's own /usr/bin/find would produce. A test that only exercises GNU find
# cannot see this bug at all, because GNU find is the half that always worked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAP="$ROOT/bin/fm-scratch-reap.sh"
TMP_ROOT=$(fm_test_tmproot fm-scratch-reap-tests)

# The reaper's second pass sweeps FM_SCRATCH_TMP_ROOT/fm-* and DELETES what it finds.
# Left at its default it would rm -rf the developer's own live task temp roots - the
# very defect this suite guards - so every test is pointed at an empty scratch root,
# and the one test that exercises that pass overrides it with its own fixture.
export FM_SCRATCH_TMP_ROOT="$TMP_ROOT/no-sweep"
mkdir -p "$FM_SCRATCH_TMP_ROOT"

# Build a fake harness scratch root with a dead session, a fresh session, and a
# non-session sibling. Echoes the root path.
make_scratch() {
  local name=$1 root
  root="$TMP_ROOT/$name/claude-1001"
  mkdir -p "$root/-proj-a/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/scratchpad" \
           "$root/-proj-b/11111111-2222-3333-4444-555555555555/scratchpad" \
           "$root/bundled-skills/2.1.210"
  echo dead > "$root/-proj-a/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/scratchpad/f"
  age_days "$root/-proj-a/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/scratchpad/f" 3
  echo live > "$root/-proj-b/11111111-2222-3333-4444-555555555555/scratchpad/f"
  echo skill > "$root/bundled-skills/2.1.210/y"
  printf '%s\n' "$root"
}

# Backdate a file N days, on either flavor of the toolchain. `touch -d '3 days ago'`
# is GNU-only - BSD touch wants an ISO stamp for -d and silently leaves the mtime at
# now, which quietly turns a "dead" fixture into a live one. `touch -t` is POSIX and
# understood by both; only the date arithmetic that produces the stamp differs.
age_days() {  # <file> <days>
  local f=$1 days=$2 stamp
  stamp=$(date -v-"${days}"d +%Y%m%d%H%M.%S 2>/dev/null) ||
    stamp=$(date -d "$days days ago" +%Y%m%d%H%M.%S 2>/dev/null) ||
    fail "no portable way to compute a timestamp $days days ago"
  touch -t "$stamp" "$f"
}

# Put a stub `find` first on PATH that refuses one specific primary and delegates
# everything else to the platform's real find. This is how a macOS-only failure is
# made visible on a GNU runner: the stub reproduces exactly what BSD find does with a
# primary it does not implement - a diagnostic on stderr, a non-zero exit, and NOTHING
# on stdout, which is the empty result the old probe misread as "nothing recent here".
# Echoes the dir to prepend to PATH.
make_find_stub() {  # <name> <primary-to-reject> [reject-value-prefix]
  local name=$1 primary=$2 valpfx=${3:-} dir real
  dir="$TMP_ROOT/stub-$name"
  mkdir -p "$dir"
  real=$(PATH=/usr/bin:/bin command -v find) || fail "no real find to delegate to"
  cat > "$dir/find" <<EOF
#!/usr/bin/env bash
# Stub find: rejects '$primary' the way BSD find does, delegates the rest.
armed=0
for a in "\$@"; do
  if [ "\$armed" = 1 ]; then
    case "\$a" in
      ${valpfx:-@}*) echo "find: Can't parse date/time: \$a" >&2; exit 1 ;;
    esac
    armed=0
  fi
  case "\$a" in
    "$primary")
      if [ -z "$valpfx" ]; then
        echo "find: $primary: unknown primary or operator" >&2; exit 1
      fi
      armed=1 ;;
  esac
done
exec $real "\$@"
EOF
  chmod +x "$dir/find"
  printf '%s\n' "$dir"
}

# Put a stub `find` first on PATH that fails the way a real walk fails on ONE bad
# entry - a diagnostic on stderr, non-zero exit, nothing on stdout - but only for a
# path matching <substr>, and only for a RECURSIVE walk. Anything carrying -maxdepth
# is delegated untouched, so the reaper's own one-directory probes (the capability
# gate and the hard-ceiling stat) still answer. That is the whole point: a single
# unreadable subdir must not read as "find is broken".
make_find_walk_error_stub() {  # <name> <path-substr>
  local name=$1 substr=$2 dir real
  dir="$TMP_ROOT/stub-$name"
  mkdir -p "$dir"
  real=$(PATH=/usr/bin:/bin command -v find) || fail "no real find to delegate to"
  cat > "$dir/find" <<EOF
#!/usr/bin/env bash
# Stub find: one unreadable entry inside any recursive walk of *$substr*.
shallow=0
for a in "\$@"; do [ "\$a" = -maxdepth ] && shallow=1; done
if [ "\$shallow" = 0 ]; then
  for a in "\$@"; do
    case "\$a" in
      *$substr*) echo "find: \$a/unreadable: Permission denied" >&2; exit 1 ;;
    esac
  done
fi
exec $real "\$@"
EOF
  chmod +x "$dir/find"
  printf '%s\n' "$dir"
}

# Add a third session dir whose tree the stub above will fail to walk. Aged <days>
# on both its file and the dir itself, so the hard-ceiling backstop is exercisable.
add_unwalkable() {  # <root> <days>
  local root=$1 days=$2 d
  d="$root/-proj-c/99999999-8888-7777-6666-555555555555"
  mkdir -p "$d/scratchpad"
  echo unwalkable > "$d/scratchpad/f"
  age_days "$d/scratchpad/f" "$days"
  age_days "$d" "$days"   # last: creating entries below would bump it again
  printf '%s\n' "$d"
}

DEAD=-proj-a/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
LIVE=-proj-b/11111111-2222-3333-4444-555555555555

test_reaps_dead_spares_fresh() {
  local root
  root=$(make_scratch reap)
  FM_SCRATCH_ROOT="$root" "$REAP" >/dev/null 2>&1 || fail "reaper exited non-zero"
  [ ! -e "$root/$DEAD" ] || fail "dead session (untouched 3d) was not reaped"
  [ -e "$root/$LIVE" ] || fail "fresh session was reaped (must be spared)"
  [ -e "$root/bundled-skills/2.1.210" ] || fail "non-session sibling was reaped"
  pass "reaps a session untouched past the threshold, spares a fresh one and non-session siblings"
}

test_cleans_emptied_parent() {
  local root
  root=$(make_scratch parent)
  FM_SCRATCH_ROOT="$root" "$REAP" >/dev/null 2>&1
  [ ! -e "$root/-proj-a" ] || fail "emptied project-encoded parent dir was left behind"
  [ -e "$root/-proj-b" ] || fail "a parent that still holds a live session was removed"
  pass "removes an emptied project-encoded parent, keeps a populated one"
}

test_protect_spares_regardless_of_age() {
  local root
  root=$(make_scratch protect)
  FM_SCRATCH_ROOT="$root" "$REAP" --protect aaaaaaaa >/dev/null 2>&1
  [ -e "$root/$DEAD" ] || fail "--protect did not spare the matching dead session"
  # --self is an alias for the same protection.
  root=$(make_scratch self)
  FM_SCRATCH_ROOT="$root" "$REAP" --self aaaaaaaa-bbbb >/dev/null 2>&1
  [ -e "$root/$DEAD" ] || fail "--self did not spare the matching session"
  pass "--protect / --self spare a dir regardless of age"
}

test_dry_run_deletes_nothing() {
  local root out
  root=$(make_scratch dry)
  out=$(FM_SCRATCH_ROOT="$root" "$REAP" --dry-run 2>&1)
  [ -e "$root/$DEAD" ] || fail "--dry-run deleted a session dir"
  assert_contains "$out" 'would reap' "--dry-run: reports the candidate"
  pass "--dry-run reports candidates and deletes nothing"
}

test_refuses_non_harness_root() {
  local dir rc=0
  dir="$TMP_ROOT/notclaude/random-dir"
  mkdir -p "$dir"
  FM_SCRATCH_ROOT="$dir" "$REAP" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "reaper did not refuse a root that is not claude-<uid> (rc=$rc)"
  [ -e "$dir" ] || fail "reaper touched a refused root"
  pass "refuses a root whose basename is not claude-<uid>"
}

test_max_age_threshold_respected() {
  local root
  root=$(make_scratch age)
  # A 96h threshold spares the 3-day-old (72h) dead session.
  FM_SCRATCH_ROOT="$root" "$REAP" --max-age-hours 96 >/dev/null 2>&1
  [ -e "$root/$DEAD" ] || fail "session younger than the threshold was reaped"
  # A 1h threshold reaps it.
  FM_SCRATCH_ROOT="$root" "$REAP" --max-age-hours 1 >/dev/null 2>&1
  [ ! -e "$root/$DEAD" ] || fail "session older than a 1h threshold was not reaped"
  pass "--max-age-hours gates reaping by the untouched window"
}

# The defect this guards: with `find` rejecting the GNU-only @epoch form, the old probe
# produced no stdout, the reaper read that as "no recent file here", and it deleted
# every session dir it enumerated - live ones included, on every macOS run.
test_live_session_survives_bsd_find() {
  local root stub
  root=$(make_scratch bsdfind)
  stub=$(make_find_stub bsd -newermt @)
  PATH="$stub:$PATH" FM_SCRATCH_ROOT="$root" "$REAP" >/dev/null 2>&1
  [ -e "$root/$LIVE" ] ||
    fail "live session reaped under a find that rejects -newermt @<epoch> (the macOS path)"
  # The other half: the probe must still WORK on that find, not just spare everything.
  [ ! -e "$root/$DEAD" ] ||
    fail "dead session was not reaped under a find that rejects -newermt @<epoch>"
  pass "a live session survives a find that rejects the GNU-only date form"
}

# Rail 4, independent of any syntax: when the probe itself cannot run, the answer is
# unknown, and an unknown answer must never clear a deletion. This is the GLOBAL
# half - a find that cannot evaluate the question is broken for every directory
# alike, so nothing at all is reaped. The per-directory half is (i) and (j).
test_fails_closed_when_probe_cannot_run() {
  local root stub out
  root=$(make_scratch failclosed)
  stub=$(make_find_stub noprobe -mmin)
  out=$(PATH="$stub:$PATH" FM_SCRATCH_ROOT="$root" "$REAP" 2>/dev/null)
  [ -e "$root/$DEAD" ] ||
    fail "reaper deleted a session dir when its liveness probe could not run"
  [ -e "$root/$LIVE" ] || fail "reaper deleted the live session dir as well"
  assert_contains "$out" 'refusing to reap on an unknown answer' \
    "fail-closed spare is reported rather than silent"
  pass "a probe that cannot run spares the dir and says so"
}

# The overshoot this guards: treating every non-zero find status as "the probe is
# broken" exempted a dir with one unreadable entry on every run, forever, behind a
# bare count. It must be spared THIS run, named, and the rest of the sweep must
# carry on - a bad entry in one tree says nothing about any other tree.
test_traversal_error_spares_that_dir_only() {
  local root stub bad out
  root=$(make_scratch walkerr)
  bad=$(add_unwalkable "$root" 3)
  stub=$(make_find_walk_error_stub walkerr 99999999)
  out=$(PATH="$stub:$PATH" FM_SCRATCH_ROOT="$root" "$REAP" 2>/dev/null)
  [ -e "$bad" ] || fail "a dir whose walk errored was reaped anyway"
  [ ! -e "$root/$DEAD" ] ||
    fail "one unwalkable dir stopped the whole sweep - the other dirs answered fine"
  [ -e "$root/$LIVE" ] || fail "the live session was reaped"
  assert_contains "$out" 'could not be fully walked' "the spare states its reason"
  assert_contains "$out" '99999999' "the spare NAMES the dir, not just a count"
  pass "a traversal error spares only that dir, names it, and the sweep continues"
}

# ... and the sparing is transient, not a permanent exemption: past the hard ceiling
# the dir's own mtime answers on its own, and scratch stops growing without bound.
test_hard_ceiling_reaps_an_unwalkable_dir() {
  local root stub bad out
  root=$(make_scratch ceiling)
  bad=$(add_unwalkable "$root" 3)
  stub=$(make_find_walk_error_stub ceiling 99999999)
  # Ceiling = 1x the window, so the 3-day-old dir is past a 48h window.
  out=$(PATH="$stub:$PATH" FM_SCRATCH_HARD_CEILING_MULTIPLE=1 \
        FM_SCRATCH_ROOT="$root" "$REAP" 2>/dev/null)
  [ ! -e "$bad" ] ||
    fail "an unwalkable dir untouched past the hard ceiling was spared forever"
  [ -e "$root/$LIVE" ] || fail "the live session was reaped"
  assert_contains "$out" 'hard ceiling' "the ceiling reap says why it went ahead"
  pass "an unwalkable dir past the hard ceiling is reaped rather than exempt forever"
}

# -mmin -0 matches no file at all, so a 0 window would report every session dir -
# including the live callers' - as having nothing recent in it, and delete them all.
test_rejects_zero_max_age() {
  local root rc=0 out
  root=$(make_scratch zeroage)
  out=$(FM_SCRATCH_ROOT="$root" "$REAP" --max-age-hours 0 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "--max-age-hours 0 was accepted (rc=$rc)"
  [ -e "$root/$LIVE" ] || fail "--max-age-hours 0 deleted the live session"
  [ -e "$root/$DEAD" ] || fail "--max-age-hours 0 deleted a session dir despite refusing"
  assert_contains "$out" 'greater than 0' "the refusal says what is wrong"
  pass "--max-age-hours 0 is refused rather than silently reaping everything"
}

# A directory's mtime moves only when an entry inside it is created, renamed or
# unlinked - never when a file already inside it is appended to. A task temp root is
# created once at spawn and written INTO for the rest of the task, so under the old
# bare `-mmin +1440` rule it read as abandoned while it was in constant use, and a
# live crew's workspace was deleted out from under it. The dead root in the same
# sweep keeps this honest: sparing everything would pass otherwise.
test_fm_tmp_root_in_use_survives_stale_dir_mtime() {
  local root sweep live dead out
  root=$(make_scratch fmtmp)
  sweep="$TMP_ROOT/fmtmp-sweep"
  live="$sweep/fm-home-live-task"
  dead="$sweep/fm-home-dead-task"
  mkdir -p "$live" "$dead"
  echo working > "$live/worker.log"
  echo orphan > "$dead/worker.log"
  age_days "$dead/worker.log" 3
  age_days "$live" 3   # last: creating the entries above bumped the dirs' own mtime
  age_days "$dead" 3

  out=$(FM_SCRATCH_ROOT="$root" FM_SCRATCH_TMP_ROOT="$sweep" "$REAP" 2>/dev/null) ||
    fail "reaper exited non-zero"
  [ -e "$live" ] ||
    fail "a task temp root written into seconds ago was reaped on its stale directory mtime"
  # The rails cannot answer without a readable /proc (macOS has none), and the
  # documented outcome there is to reap NOTHING rather than fall back to the mtime that
  # caused this defect. Assert whichever contract this platform is under - taking the
  # answer from the reaper's own output, never re-deriving it here, because a gate
  # written from /proc's shape has to be edited every time a rail is added, and the one
  # that was not edited is how this test went red on a box it was meant to pass on.
  # Both branches keep the live root, which is what the test is for.
  case "$out" in
    *'unanswerable here'*)
      [ -e "$dead" ] || fail "reaped after refusing the rails - the refusal must delete nothing"
      pass "with no way to ask /proc what is alive the task-temp pass reaps nothing and says so" ;;
    *)
      [ ! -e "$dead" ] || fail "a genuinely orphaned task temp root was not reclaimed"
      pass "an in-use task temp root survives a stale directory mtime; a dead one is still reclaimed" ;;
  esac
}

# The incident of 2026-08-24, reproduced. A crewmate's task temp root is exported into
# its pane as GOTMPDIR at spawn and then named by every process in that tree, while
# NOTHING chdirs into it and nothing holds a file open there outside a build - measured
# on this box, zero cwd and zero fd references against 9 and 13 environment ones. So the
# directory here is given the exact shape that lost work: stale own mtime, no content
# written for days, no cwd and no open fd inside it, and one live process carrying its
# path in its environment. Every rail but the environment one says "dead".
test_fm_tmp_root_named_in_live_environ_survives() {
  local root sweep held dead out pid
  root=$(make_scratch fmenv)
  sweep="$TMP_ROOT/fmenv-sweep"
  held="$sweep/fm-home-env-task"
  dead="$sweep/fm-home-dead-task"
  mkdir -p "$held" "$dead"
  echo built > "$held/artifact"
  echo orphan > "$dead/artifact"
  age_days "$held/artifact" 3
  age_days "$dead/artifact" 3
  age_days "$held" 3   # last: creating the entries above bumped the dirs' own mtime
  age_days "$dead" 3

  # env, not an exported shell variable: /proc/<pid>/environ is the environment the
  # process was EXEC'd with, so a variable set after the fork would never appear there.
  # The child's cwd is the caller's, not $held, and it opens nothing inside it.
  env FM_SCRATCH_TEST_HOLD="$held" sleep 30 &
  pid=$!
  out=$(FM_SCRATCH_ROOT="$root" FM_SCRATCH_TMP_ROOT="$sweep" "$REAP" 2>/dev/null) ||
    fail "reaper exited non-zero"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  [ -e "$held" ] ||
    fail "a task temp root named in a live process's environment was reaped - this is the 2026-08-24 incident"
  # Which contract this platform is under is the reaper's own answer, not something to
  # re-derive here: a gate written from /proc's shape would have to model -readable,
  # grep -z and the rest, and a test that models the implementation stops testing it.
  case "$out" in
    *'unanswerable here'*)
      [ -e "$dead" ] || fail "reaped after refusing the rails - the refusal must delete nothing"
      pass "with no way to read a process environment the task-temp pass reaps nothing and says so" ;;
    *)
      [ ! -e "$dead" ] ||
        fail "nothing was reclaimed, so sparing the held root proves nothing about the environment rail"
      pass "a task temp root named only in a live process's environment survives; its unnamed twin is reclaimed" ;;
  esac
}

test_reaps_dead_spares_fresh
test_cleans_emptied_parent
test_protect_spares_regardless_of_age
test_dry_run_deletes_nothing
test_refuses_non_harness_root
test_max_age_threshold_respected
test_live_session_survives_bsd_find
test_fails_closed_when_probe_cannot_run
test_traversal_error_spares_that_dir_only
test_hard_ceiling_reaps_an_unwalkable_dir
test_rejects_zero_max_age
test_fm_tmp_root_in_use_survives_stale_dir_mtime
test_fm_tmp_root_named_in_live_environ_survives
