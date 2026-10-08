#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse mocks: those encode terminal and
# lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1


# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. The first call installs the cleanup trap. A test file that needs
# extra teardown (e.g. killing a daemon) should define its own EXIT trap and
# call fm_test_cleanup from inside it so registered dirs are still removed.

FM_TEST_CLEANUP_DIRS=()

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  # lib.sh's own roots (below) belong to the shell that sourced it. This function
  # also runs as the EXIT trap fm_test_tmproot sets inside each $(...) subshell,
  # which must not take them.
  [ "$BASHPID" = "${FM_TEST_LIB_PID:-}" ] || return 0
  for d in "${FM_TEST_LIB_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  # PHYSICALLY RESOLVED, because production code resolves the paths it is handed
  # (`cd ... && pwd -P`) and a fixture path that does not match its own resolution
  # is a fake failure. On macOS TMPDIR is /var/folders/..., a symlink into
  # /private/var/folders/..., which silently broke every knowledge-graph fixture
  # that compared a recorded path against a resolved one.
  root=$(cd "$root" && pwd -P)
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$root")
  printf '%s\n' "$root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# fm_th_slot <name> <status> <path> [lease-holder]: one slot of a stubbed
# `treehouse status --json` (treehouse v3+), as one JSON line. A stub answers
# `status --json` with `jq -s .` over these lines, and `status --help` with a line
# naming --json - which is how bin/fm-pool-lib.sh detects that interface.
fm_th_slot() {
  jq -nc --arg n "$1" --arg s "$2" --arg p "$3" --arg h "${4:-}" \
    '{name: $n, status: $s, path: $p, lease_holder: $h}'
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}

# --- shared-peer cache isolation --------------------------------------------
#
# bin/fm-peer-lib.sh keeps the per-clone write lock and the live-session registry
# in ONE per-user directory, because their whole job is to be shared between
# instances - so its default is the operator's real ~/.cache/firstmate, and any
# suite that runs fleet sync, the session lock or the updater would write there.
# Redirected here, once, rather than in each suite: a test that has to REMEMBER to
# isolate itself is a test that will forget. Set FM_PEER_CACHE_DIR before sourcing
# to point a suite at a directory it wants to inspect.
#
# Both roots are made and registered here in the sourcing shell, not through
# $(fm_test_tmproot): that registers in a subshell and the root is never removed.
FM_TEST_LIB_PID=$BASHPID
FM_TEST_LIB_DIRS=()
trap fm_test_cleanup EXIT
fm_test_lib_root() {
  local root
  root=$(mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX")
  root=$(cd "$root" && pwd -P)
  FM_TEST_LIB_DIRS+=("$root")
  printf -v "$2" '%s' "$root"
}
if [ -z "${FM_PEER_CACHE_DIR:-}" ]; then
  fm_test_lib_root fm-peer-cache FM_PEER_CACHE_DIR
fi
export FM_PEER_CACHE_DIR

# --- host /tmp isolation -----------------------------------------------------
#
# bin/fm-scratch-reap.sh and bin/fm-disk-guard.sh (both run by bin/fm-bootstrap.sh)
# default to walking and deleting from the host /tmp and $HOME's caches, and
# bin/fm-spawn.sh creates task temp roots under FM_SCRATCH_TMP_ROOT. Left at their
# defaults, a suite that runs bootstrap walks the developer's real /tmp - ~300s on a
# 27k-entry /tmp - and can delete from it. Redirected here, once, for the same reason
# as the peer cache above. A suite that exercises a janitor sets its own roots.
fm_test_lib_root fm-janitor FM_TEST_JANITOR_ROOT
mkdir -p "$FM_TEST_JANITOR_ROOT/claude-0" "$FM_TEST_JANITOR_ROOT/tmp"
export FM_SCRATCH_ROOT="${FM_SCRATCH_ROOT:-$FM_TEST_JANITOR_ROOT/claude-0}"
export FM_SCRATCH_TMP_ROOT="${FM_SCRATCH_TMP_ROOT:-$FM_TEST_JANITOR_ROOT/tmp}"
export FM_DISK_TMP_ROOT="${FM_DISK_TMP_ROOT:-$FM_TEST_JANITOR_ROOT/tmp}"
export FM_DISK_PATH="${FM_DISK_PATH:-$FM_TEST_JANITOR_ROOT}"
export FM_DISK_CACHES="${FM_DISK_CACHES-}"

# --- host memory isolation ---------------------------------------------------
#
# bin/fm-mem-lib.sh makes spawns wait and pool warms skip while the host is short of
# memory, and puts crews in a real systemd scope. A suite must not stall or skip
# because the developer's box is busy, so it reads an ample fake meminfo and makes
# no scope. A suite that exercises either sets its own values.
printf 'MemTotal: 67108864 kB\nMemAvailable: 67108864 kB\n' > "$FM_TEST_JANITOR_ROOT/meminfo"
export FM_MEMINFO="${FM_MEMINFO:-$FM_TEST_JANITOR_ROOT/meminfo}"
export FM_CREW_MEMORY_HIGH="${FM_CREW_MEMORY_HIGH-off}"
