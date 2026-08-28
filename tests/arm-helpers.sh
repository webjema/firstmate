#!/usr/bin/env bash
# tests/arm-helpers.sh - the shared fixture for driving a REAL bin/fm-watch-arm.sh:
# a self-contained firstmate home with a scripted stand-in watcher, and the two ways
# to run an arm against it.
#
# Two suites drive the arm and must agree on the stand-in, or one of them starts
# testing a watcher the other does not have:
#   tests/fm-watch-arm-supervision.test.sh - what the arm may WAKE firstmate for
#   tests/fm-watch-arm-hosting.test.sh     - WHERE the arm runs the watcher
#
# Set ARM_HOST before sourcing (or before the first run_arm) to pin FM_WATCH_HOST for
# every arm the suite starts. Leaving hosting on `auto` in a suite that does not
# provide a private tmux socket would put watcher sessions on the HOST's tmux server.
# shellcheck shell=bash

ARM_HOST=${ARM_HOST:-child}

# A self-contained firstmate home whose bin/ holds the REAL arm and lib next to a
# SCRIPTED stand-in watcher. The arm resolves its watcher as $SCRIPT_DIR/fm-watch.sh
# and validates the lock's recorded watcher-path and fm-home against its own, so the
# stand-in has to live in that bin/ to be confirmable at all.
make_arm_case() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/bin" "$dir/state"
  # fm-supervision-live.sh and fm-wake-drain.sh come along because a case asks the
  # home the same questions firstmate does, and both resolve their libs and the
  # watcher path from their OWN bin/ - run from the repo they would answer about the
  # repo's state dir, not the case's.
  cp "$ROOT/bin/fm-watch-arm.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-wake-kind-lib.sh" \
    "$ROOT/bin/fm-supervision-live.sh" "$ROOT/bin/fm-supervision-lib.sh" \
    "$ROOT/bin/fm-detach-lib.sh" "$ROOT/bin/fm-wake-drain.sh" "$dir/bin/"
  cat > "$dir/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
# Scripted stand-in for the watcher. It takes the singleton lock exactly the way
# the real one does (live pid + identity + fresh beacon), so the arm's honesty gate
# confirms it, then acts out one scenario from state/.fake-watch-mode:
#   quiet   - hold the lock briefly, release it, exit 0 saying nothing
#   wake    - release, then print one wake reason line
#   dgwake  - release, then print a BARE "disk-guard" line, the shape the real
#             watcher's wake() emits for the disk holdback
#   enqueue - append a durable wake record, release, say nothing
#   hold    - hold the lock and beat until signalled. The sleep is interruptible so
#             a TERM lands NOW: bash defers a trap until the running foreground
#             command finishes, and a watcher that ignores TERM for an hour would
#             make "--restart takes the old watcher down" untestable.
#   holdwake - hold as above, then on TERM release and print one wake reason, the
#             shape a watcher takes when it is asked to stop mid-cycle.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-wake-lib.sh"
printf '%s\n' "$$" >> "$STATE/.fake-watch-runs"
mode=$(cat "$STATE/.fake-watch-mode" 2>/dev/null || echo quiet)
mkdir -p "$STATE/.watch.lock"
printf '%s\n' "$$" > "$STATE/.watch.lock/pid"
printf '%s\n' "$FM_HOME" > "$STATE/.watch.lock/fm-home"
printf '%s\n' "$SCRIPT_DIR/fm-watch.sh" > "$STATE/.watch.lock/watcher-path"
fm_pid_identity "$$" > "$STATE/.watch.lock/pid-identity"
touch "$STATE/.last-watcher-beat"
release() { rm -rf "$STATE/.watch.lock" 2>/dev/null || true; }
trap 'release; exit 143' TERM INT
# holdwake's trap goes on BEFORE the settle sleep, not in its case branch below: a
# caller that TERMs inside that first second would otherwise get the plain trap and
# no wake, and the test reading "the wake never reached the queue" would be blaming
# the queue for a stand-in that never raised one.
if [ "$mode" = holdwake ]; then
  trap 'release; fm_wake_append stale fm-probe "stale: fm-probe | class=none | idle=900s"; echo "stale: fm-probe | class=none | idle=900s"; exit 0' TERM INT
fi
sleep "${FAKE_WATCH_HOLD:-1}"
case "$mode" in
  wake) release; echo 'stale: fm-probe | class=none | idle=900s' ;;
  dgwake) release; echo 'disk-guard' ;;
  enqueue) fm_wake_append stale fm-probe 'stale: fm-probe | class=none | idle=900s'; release ;;
  hold) while :; do touch "$STATE/.last-watcher-beat"; sleep 1 & wait $! 2>/dev/null || true; done ;;
  holdwake) while :; do touch "$STATE/.last-watcher-beat"; sleep 1 & wait $! 2>/dev/null || true; done ;;
  *) release ;;
esac
exit 0
SH
  chmod +x "$dir/bin/fm-watch.sh"
  printf '%s\n' "$dir"
}

set_mode() {  # <dir> <mode>
  printf '%s\n' "$2" > "$1/state/.fake-watch-mode"
}

watcher_runs() {  # <dir>
  [ -f "$1/state/.fake-watch-runs" ] || { echo 0; return 0; }
  wc -l < "$1/state/.fake-watch-runs" | tr -d ' '
}

# The pid the arm CONFIRMED, read back from the one line that only ever names a
# confirmed watcher.
confirmed_watcher_pid() {  # <arm-output>
  sed -n 's/^watcher: started pid=\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1
}

# The production liveness gate, asked exactly as bin/fm-guard.sh asks it: this is
# what decides whether firstmate is told supervision is off.
watcher_healthy() {  # <dir>
  FM_STATE_OVERRIDE="$1/state" bash -c \
    '. "$1"; fm_watcher_healthy "$2/state" "$2/bin/fm-watch.sh" 300 "$2"' _ "$LIB" "$1"
}

pgid_of() {  # <pid>
  ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '
}

wait_for_text() {  # <file> <text> [limit]
  local file=$1 text=$2 limit=${3:-300} i=0
  while [ "$i" -lt "$limit" ]; do
    grep -qF "$text" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Every case runs the arm from the case's own bin/ with its own home and state, so
# nothing here can see or disturb the running fleet's supervision. The home is pinned
# explicitly because tests/wake-helpers.sh exports one shared FM_ROOT_OVERRIDE for the
# whole file; inheriting it would point every case - and the watcher it starts - at the
# same state dir. The scripted watcher inherits these, so both ends agree on the home
# the singleton lock records.
run_arm() {  # <dir> [args...]
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_WATCH_HOST="$ARM_HOST" \
    FM_ARM_BACKOFF_MAX=1 FM_ARM_CONFIRM_TIMEOUT=6 FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_STANDBY_POLL=0.2 FM_ARM_STANDBY_SETTLE=0.2 \
    "$dir/bin/fm-watch-arm.sh" "$@"
}

# Background an arm and set ARM_PID to the ARM's OWN pid. exec matters: without it
# $! is the wrapper subshell, and the arm's real pid - the one it writes into the
# arming marker and a second arm reports back - would never match what a case asserts.
ARM_PID=
run_arm_bg() {  # <dir> <outfile> [args...]
  local dir=$1 out=$2
  shift 2
  ( exec env FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
      FM_WATCH_HOST="$ARM_HOST" \
      FM_ARM_BACKOFF_MAX=1 FM_ARM_CONFIRM_TIMEOUT=6 FM_ARM_ATTACH_POLL=0.1 \
      FM_ARM_STANDBY_POLL=0.2 FM_ARM_STANDBY_SETTLE=0.2 \
      "$dir/bin/fm-watch-arm.sh" "$@" ) > "$out" 2>&1 &
  # Read by the sourcing test file, not here.
  # shellcheck disable=SC2034
  ARM_PID=$!
}
