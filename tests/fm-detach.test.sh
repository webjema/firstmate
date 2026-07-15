#!/usr/bin/env bash
# Tests for bin/fm-detach.sh: handing a live crew to the captain, then reclaiming
# its worktree once the captain's session is done.
#
# Detach severs only the SUPERVISION tie: it drops window= (so bin/fm-watch.sh's
# recorded_windows() and recovery stop seeing the task as a crew), stamps
# detached=/detached_window=, and clears the crew-liveness state - while leaving
# the tmux window and the worktree untouched.
#
# Reclaim is an idle gate in front of ordinary teardown: it returns the worktree
# only when the captain's session is done (window gone, or a bare shell), and it
# reuses teardown's landed-work safety verbatim, so unlanded work is protected.
#
# Matrix:
#   (a) detach a live ship crew            -> window dropped, markers set, wt kept
#   (b) detach clears crew-liveness state  -> status file removed, worktree/meta kept
#   (c) detach refuses a secondmate        -> exit 1, meta unchanged
#   (d) detach refuses a windowless task   -> exit 1 (already detached/released)
#   (e) reclaim while agent still alive     -> skipped, meta preserved, exit 0
#   (f) reclaim once the window is gone      -> teardown runs, slot returned, meta purged
#   (g) reclaim --force past a live agent    -> teardown runs, meta purged
#   (h) reclaim refuses uncommitted work     -> exit 1, meta preserved (safety reused)
#   (i) reclaim a detached meta with NO window= -> NO empty-target kill (self-destruct guard)
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

DETACH="$ROOT/bin/fm-detach.sh"
TMP_ROOT=$(fm_test_tmproot fm-detach-tests)

# Build a sandbox: project clone with an origin, a worktree on a task branch whose
# branch is PUSHED to origin (so teardown sees it as landed), and mocks for
# treehouse/tmux/gh. The tmux mock is env-driven: FM_MOCK_WINDOW_EXISTS toggles
# whether the detached window still exists, FM_MOCK_PANE_CMD its foreground
# command (claude => alive, bash => a done bare shell).
#
# The window-existence probe fm_backend_target_exists uses is `tmux list-panes`
# (window-strict), so FM_MOCK_WINDOW_EXISTS gates list-panes here. display-message
# deliberately does NOT gate on it for a pane_id read: real tmux never fails that
# for a gone window - it falls back to the session's ACTIVE window and returns a
# pane id with exit 0. Reproducing that fallback keeps the reclaim-when-gone cases
# (f)/(h) a genuine before/after guard: the pre-fix primitive read pane_id via
# display-message and so mistook a closed detached window for a still-open one.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/config" "$fakebin"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-panes)
    # fm_backend_target_exists's window-strict probe: a gone window fails
    # ("can't find window"), a live one lists its pane.
    [ "${FM_MOCK_WINDOW_EXISTS:-1}" = 1 ] && { echo "%1"; exit 0; }
    exit 1 ;;
  display-message)
    fmt="${!#}"
    case "$fmt" in
      *pane_id*)
        # Faithful to real tmux: a pane_id read never fails for a gone window;
        # it falls back to the session's active window and returns exit 0.
        echo "%1"; exit 0 ;;
      *pane_current_command*)
        [ "${FM_MOCK_WINDOW_EXISTS:-1}" = 1 ] || exit 0
        printf '%s\n' "${FM_MOCK_PANE_CMD:-bash}"; exit 0 ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

  # Force manual backlog so teardown never needs tasks-axi on PATH.
  printf 'manual\n' > "$case_dir/config/backlog-backend"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  # Push the task branch so teardown's landed-work check passes (HEAD is reachable
  # from a remote-tracking branch).
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_active_meta() {  # <case_dir> <kind>
  local case_dir=$1 kind=$2
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=PR"
}

# run <case_dir> [env KEY=VAL ...] -- <detach args...>: run fm-detach.sh with the
# case's FM_HOME and PATH-shimmed mocks. Captures OUT and CODE.
run() {
  local case_dir=$1; shift
  local envs=()
  while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done
  shift
  OUT=$(cd "$case_dir" && env "${envs[@]}" \
    FM_HOME="$case_dir" PATH="$case_dir/fakebin:$PATH" \
    "$DETACH" "$@" 2>&1) && CODE=0 || CODE=$?
}

# (a) detach a live ship crew.
c=$(make_case detach-basic)
write_active_meta "$c" ship
run "$c" -- task-x1
expect_code 0 "$CODE" "a: detach exits 0"
grep -q '^window=' "$c/state/task-x1.meta" && fail "a: window= line dropped from meta" || true
assert_grep "detached=" "$c/state/task-x1.meta" "a: detached= stamped"
assert_grep "detached_window=firstmate:fm-task-x1" "$c/state/task-x1.meta" "a: window remembered"
assert_grep "worktree=$c/wt" "$c/state/task-x1.meta" "a: worktree kept"
assert_present "$c/wt" "a: worktree not removed"
assert_contains "$OUT" "now yours to drive" "a: hand-over message"
pass "a: detach hands a live crew to the captain"

# (b) detach clears crew-liveness state but keeps the worktree and meta.
c=$(make_case detach-clears-state)
write_active_meta "$c" ship
printf 'working: mid-task\n' > "$c/state/task-x1.status"
touch "$c/state/task-x1.turn-ended" "$c/state/.wt-snap-task-x1"
run "$c" -- task-x1
expect_code 0 "$CODE" "b: detach exits 0"
assert_absent "$c/state/task-x1.status" "b: status file cleared"
assert_absent "$c/state/task-x1.turn-ended" "b: turn-ended cleared"
assert_absent "$c/state/.wt-snap-task-x1" "b: worktree snapshot cleared"
assert_present "$c/state/task-x1.meta" "b: meta kept"
pass "b: detach clears crew-liveness state"

# (c) detach refuses a secondmate.
c=$(make_case detach-refuses-secondmate)
write_active_meta "$c" secondmate
run "$c" -- task-x1
expect_code 1 "$CODE" "c: detach refuses a secondmate"
assert_contains "$OUT" "secondmate" "c: names the secondmate reason"
assert_grep "window=" "$c/state/task-x1.meta" "c: meta unchanged on refusal"
pass "c: detach refuses a secondmate"

# (d) detach refuses a task that has no live window (already detached/released).
c=$(make_case detach-refuses-windowless)
fm_write_meta "$c/state/task-x1.meta" \
  "worktree=$c/wt" "project=$c/project" "kind=ship" "mode=PR" "detached=2026-07-15T00:00:00Z"
run "$c" -- task-x1
expect_code 1 "$CODE" "d: detach refuses a windowless task"
assert_contains "$OUT" "no live crew window" "d: explains why"
pass "d: detach refuses an already-detached task"

# (e) reclaim is skipped while the captain's agent is still alive.
c=$(make_case reclaim-skips-live)
write_active_meta "$c" ship
run "$c" -- task-x1
run "$c" FM_MOCK_WINDOW_EXISTS=1 FM_MOCK_PANE_CMD=claude -- --reclaim task-x1
expect_code 0 "$CODE" "e: reclaim-skip exits 0"
assert_contains "$OUT" "still open in your session" "e: reports still-open"
assert_present "$c/state/task-x1.meta" "e: meta preserved while live"
assert_present "$c/wt" "e: worktree preserved while live"
pass "e: reclaim leaves a live session alone"

# (f) reclaim proceeds once the window is gone; teardown returns the slot.
c=$(make_case reclaim-when-gone)
write_active_meta "$c" ship
run "$c" -- task-x1
run "$c" FM_MOCK_WINDOW_EXISTS=0 -- --reclaim task-x1
expect_code 0 "$CODE" "f: reclaim exits 0"
assert_contains "$OUT" "returned to the pool" "f: reports reclaim"
assert_absent "$c/state/task-x1.meta" "f: meta purged by teardown"
pass "f: reclaim returns the worktree once the window is gone"

# (g) reclaim --force past a live agent still runs teardown.
c=$(make_case reclaim-force)
write_active_meta "$c" ship
run "$c" -- task-x1
run "$c" FM_MOCK_WINDOW_EXISTS=1 FM_MOCK_PANE_CMD=claude -- --reclaim --force task-x1
expect_code 0 "$CODE" "g: reclaim --force exits 0"
assert_absent "$c/state/task-x1.meta" "g: meta purged under --force"
pass "g: reclaim --force overrides the idle gate"

# (h) reclaim refuses when the worktree holds uncommitted work (teardown safety).
c=$(make_case reclaim-refuses-dirty)
write_active_meta "$c" ship
run "$c" -- task-x1
printf 'left behind\n' > "$c/wt/dirt.txt"
run "$c" FM_MOCK_WINDOW_EXISTS=0 -- --reclaim task-x1
expect_code 1 "$CODE" "h: reclaim refuses dirty worktree"
assert_present "$c/state/task-x1.meta" "h: meta preserved on refusal"
assert_present "$c/wt" "h: worktree preserved on refusal"
pass "h: reclaim reuses teardown's unlanded-work protection"

# (i) reclaiming a detached meta with NO window= must issue NO empty-target kill.
# This is the self-destruct guard: an empty tmux `-t` resolves to the session's
# ACTIVE window (the firstmate coordinator's own tab), so `kill-window -t ""`
# kills the coordinator. A detached meta carries detached_window= but no window=,
# and teardown must reach the kill with a non-empty target (falling back to
# detached_window=) or refuse the empty target - never `kill-window -t ""`.
# Reproduced live twice; proven here with a recording fake tmux, never a live
# empty kill. The augmented mock records every kill-window target so an empty one
# ("kill:[]") is caught; it otherwise behaves like make_case's mock.
c=$(make_case reclaim-no-empty-kill)
cat > "$c/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
klog="${FM_MOCK_KILL_LOG:-/dev/null}"
case "${1:-}" in
  kill-window)
    tgt=""; prev=""
    for a in "$@"; do [ "$prev" = "-t" ] && tgt="$a"; prev="$a"; done
    printf 'kill:[%s]\n' "$tgt" >> "$klog"
    exit 0 ;;
  list-panes)
    [ "${FM_MOCK_WINDOW_EXISTS:-1}" = 1 ] && { echo "%1"; exit 0; }
    exit 1 ;;
  display-message)
    fmt="${!#}"
    case "$fmt" in
      *pane_id*) echo "%1"; exit 0 ;;
      *pane_current_command*)
        [ "${FM_MOCK_WINDOW_EXISTS:-1}" = 1 ] || exit 0
        printf '%s\n' "${FM_MOCK_PANE_CMD:-bash}"; exit 0 ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$c/fakebin/tmux"
# A detached-crew meta: detached_window= remembered, but window= dropped, exactly
# as fm-detach.sh leaves it. The captain's window is already closed.
fm_write_meta "$c/state/task-x1.meta" \
  "detached=2026-07-15T00:00:00Z" \
  "detached_window=firstmate:fm-task-x1" \
  "worktree=$c/wt" \
  "project=$c/project" \
  "kind=ship" \
  "mode=PR"
: > "$c/state/killlog"
run "$c" FM_MOCK_WINDOW_EXISTS=0 FM_MOCK_KILL_LOG="$c/state/killlog" -- --reclaim task-x1
expect_code 0 "$CODE" "i: reclaim of a windowless detached task exits 0"
assert_no_grep 'kill:[]' "$c/state/killlog" "i: NO empty-target kill-window issued (would kill the coordinator)"
assert_grep 'kill:[' "$c/state/killlog" "i: the reclaim path did exercise the kill (guard is not vacuous)"
assert_absent "$c/state/task-x1.meta" "i: meta purged by teardown once reclaimed"
pass "i: reclaiming a detached task with no window= never issues an empty-target kill"
