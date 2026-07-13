#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-state.sh - the deterministic crew-current-state
# helper.
#
# The status file (state/<id>.status) is a best-effort append-only EVENT LOG, so
# `tail -1` of it reports the last event, not the current state. fm-crew-state
# reads the LIVE source first (the recorded backend endpoint's busy signature)
# and only then falls back to the log, reconciling a possibly-stale log line
# against it. These cases pin every branch of that logic, hermetically, over real
# throwaway git repos with a fake `tmux` (the pane source):
#   (a) busy pane                                                 -> working/pane
#   (b) busy pane + stale needs-decision/blocked log = SUPERSEDED -> working/pane
#   (c) idle pane falls to the status-log verb                    -> status-log
#   (d) keyed status syntax, declared pauses, and the configurable pause verb
#   (e) a decision-closing `resolved:` event is never a state
#   (f) kind=secondmate: idle pane is healthy, so no busy check at all
#   (g) dead/unreadable endpoint: unknown/none, never a stale log line
#   (h) torn-down worktree / missing meta                         -> unknown/none
#   (i) crew_is_provably_working end-to-end over the REAL helper (not a canned
#       fake fm-crew-state.sh verdict): a busy pane is absorbed, a stopped crew
#       with an idle pane still surfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state)
fm_git_identity fmtest fmtest@example.invalid

# A real git repo checked out on <branch>, so a case dir looks like a live crew
# worktree rather than a bare directory.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
}

# A fakebin with a fake `tmux` serving a busy or idle pane from the FM_FAKE_* env
# the tests set.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# Run the helper for one case dir. FM_FAKE_* env (busy flags) are read from the
# caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  FM_FAKE_BUSY=0
  FM_FAKE_TMUX_MISSING=0
  export FM_FAKE_BUSY FM_FAKE_TMUX_MISSING
}

# --- (a) the busy pane is the live, positive evidence ------------------------

test_busy_pane_is_working() {
  reset_fakes
  local d; d=$(new_case busy)
  make_repo_on_branch "$d/wt" fm/feat-h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h.meta" "window=fm:fm-feat-h" "worktree=$d/wt" "kind=ship"
  FM_FAKE_BUSY=1
  local out; out=$(run_crew_state "$d" feat-h)
  assert_contains "$out" "state: working" "busy pane -> working"
  assert_contains "$out" "source: pane" "busy pane -> pane source"
  pass "a busy pane reads working from the pane"
}

# --- (b) a busy pane SUPERSEDES a stale decision line ------------------------
# After firstmate answers a needs-decision (or clears a blocker) the crew resumes
# silently: it appends nothing. A raw `tail` of the log would re-escalate settled
# work forever. The live pane read is what makes that deterministic.

test_busy_pane_supersedes_stale_needs_decision() {
  reset_fakes
  local d; d=$(new_case superseded-nd)
  make_repo_on_branch "$d/wt" fm/feat-nd
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-nd.meta" "window=fm:fm-feat-nd" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: which database?\n' > "$d/state/feat-nd.status"
  FM_FAKE_BUSY=1
  local out; out=$(run_crew_state "$d" feat-nd)
  assert_contains "$out" "state: working" "a resumed crew must not report the answered decision"
  assert_contains "$out" "source: pane" "the live pane outranks the log"
  assert_contains "$out" "superseded" "the stale log line is flagged superseded"
  pass "a busy pane supersedes a stale needs-decision log line"
}

test_busy_pane_supersedes_stale_blocked() {
  reset_fakes
  local d; d=$(new_case superseded-blocked)
  make_repo_on_branch "$d/wt" fm/feat-b
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-b.meta" "window=fm:fm-feat-b" "worktree=$d/wt" "kind=ship"
  printf 'blocked: needs a token\n' > "$d/state/feat-b.status"
  FM_FAKE_BUSY=1
  local out; out=$(run_crew_state "$d" feat-b)
  assert_contains "$out" "state: working" "an unblocked crew must not report the cleared blocker"
  assert_contains "$out" "superseded" "the stale blocked line is flagged superseded"
  pass "a busy pane supersedes a stale blocked log line"
}

# --- (c)/(d) idle pane falls back to the status log --------------------------

test_idle_pane_uses_log() {
  reset_fakes
  local d; d=$(new_case idle)
  make_repo_on_branch "$d/wt" fm/feat-i
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-i.meta" "window=fm:fm-feat-i" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: which database?\n' > "$d/state/feat-i.status"
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: needs-decision" "needs-decision log -> needs-decision"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  assert_contains "$out" "which database?" "the decision summary is carried in the detail"
  pass "an idle pane uses the status-log verb"
}

test_idle_pane_maps_every_known_verb() {
  reset_fakes
  local d out; d=$(new_case verbs)
  make_repo_on_branch "$d/wt" fm/feat-v
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-v.meta" "window=fm:fm-feat-v" "worktree=$d/wt" "kind=ship"
  local pair verb want
  for pair in 'working:working' 'blocked:blocked' 'done:done' 'failed:failed'; do
    verb=${pair%%:*}
    want=${pair##*:}
    printf '%s: note\n' "$verb" > "$d/state/feat-v.status"
    out=$(run_crew_state "$d" feat-v)
    assert_contains "$out" "state: $want" "status verb $verb did not map to $want"
    assert_contains "$out" "source: status-log" "status verb $verb did not read from the log"
  done
  # An unrecognized verb is not a state at all.
  printf 'chatting: hello\n' > "$d/state/feat-v.status"
  out=$(run_crew_state "$d" feat-v)
  assert_contains "$out" "state: unknown" "an unrecognized verb must not become a state"
  assert_contains "$out" "source: none" "an unrecognized verb is not a status-log state source"
  pass "the status-log verb mapping covers every recognized state"
}

test_idle_pane_uses_keyed_log() {
  reset_fakes
  local d; d=$(new_case keyed-idle)
  make_repo_on_branch "$d/wt" fm/feat-keyed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-keyed.meta" "window=fm:fm-feat-keyed" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision [key=q1]: which database?\n' > "$d/state/feat-keyed.status"
  local out; out=$(run_crew_state "$d" feat-keyed)
  assert_contains "$out" "state: needs-decision" "keyed needs-decision log -> needs-decision"
  assert_contains "$out" "which database?" "key token is excluded from status detail"
  pass "an idle pane parses keyed status syntax"
}

# A DECLARED external-wait pause reports state: paused, so a supervisor reading the
# crew sees a distinct pause (and its reason) rather than a wedge-suspect idle.
# This is the reader half the watcher/daemon build on.
test_idle_pane_paused() {
  reset_fakes
  local d; d=$(new_case paused)
  make_repo_on_branch "$d/wt" fm/feat-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pause.meta" "window=fm:fm-feat-pause" "worktree=$d/wt" "kind=ship"
  printf 'paused: holding for the upstream tool release\n' > "$d/state/feat-pause.status"
  local out; out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "paused log -> paused"
  assert_contains "$out" "source: status-log" "idle pause -> status-log source"
  assert_contains "$out" "holding for the upstream tool release" "the pause reason is carried in the detail"
  pass "an idle pane on a paused: status reports state: paused with its reason"
}

test_idle_pane_custom_paused_verb() {
  reset_fakes
  local d; d=$(new_case custom-paused)
  make_repo_on_branch "$d/wt" fm/feat-custom-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-custom-pause.meta" "window=fm:fm-feat-custom-pause" "worktree=$d/wt" "kind=ship"
  printf 'awaiting: vendor maintenance window\n' > "$d/state/feat-custom-pause.status"
  local out; out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: paused" "custom paused verb -> paused"
  assert_contains "$out" "source: status-log" "custom paused verb -> status-log source"
  assert_contains "$out" "vendor maintenance window" "custom pause preserves its reason"
  printf 'paused: default verb no longer selected\n' > "$d/state/feat-custom-pause.status"
  out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: unknown" "custom paused verb replaces the default"
  pass "an idle pane honors the configured paused verb"
}

# --- (e)/(f) resolved events, and secondmate idleness ------------------------
# A trailing keyed resolved: event is a decision-CLOSING event, not a state verb.
# It must never become the current state or leak its resolution prose as the
# detail: a healthy idle secondmate that just closed a keyed decision falls through
# to the idle default (unknown/none), not `unknown` with the resolution note as its
# `doing`. Regression for the bearings render bug where such a secondmate showed
# state=unknown with resolution prose. The one-owner keyed fold in fm-classify-lib.sh
# is untouched; this only stops the deriver from reading a non-state event as state.
test_idle_secondmate_resolved_event_not_state() {
  reset_fakes
  local d; d=$(new_case resolved-idle)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "home=$d/wt"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$d/state/mate.status"
  printf 'resolved [key=race]: went with subscribe-before-write\n' >> "$d/state/mate.status"
  local out; out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "resolved-then-idle secondmate is not a spurious state"
  assert_contains "$out" "source: none" "a resolved event is not treated as a status-log state source"
  assert_not_contains "$out" "subscribe-before-write" "resolution prose must not leak into the detail"
  # A bare (non-keyed) resolved: closes the default key and behaves the same.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "source: none" "a bare resolved: is not a state source either"
  assert_not_contains "$out" "infra access granted" "bare resolution prose must not leak into the detail"
  # Control: a genuine trailing state verb still renders from the log.
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a real trailing state verb still renders"
  assert_contains "$out" "reconciling routed items" "a real state line still carries its detail"
  pass "a trailing resolved: event does not corrupt state render (idle stays idle)"
}

# A secondmate sits on its own watcher, so a BUSY pane is not even consulted: its
# state comes from the log. (An idle secondmate pane is healthy, not a wedge.)
test_secondmate_skips_the_busy_check() {
  reset_fakes
  local d; d=$(new_case secondmate-busy)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate2.meta" "window=fm:fm-mate2" "worktree=$d/wt" "kind=secondmate" "home=$d/wt"
  printf 'needs-decision: route this to whom?\n' > "$d/state/mate2.status"
  FM_FAKE_BUSY=1
  local out; out=$(run_crew_state "$d" mate2)
  assert_contains "$out" "state: needs-decision" "a secondmate's open decision must survive a busy pane"
  assert_contains "$out" "source: status-log" "a secondmate is read from its log, not the busy signature"
  pass "kind=secondmate skips the busy-pane check and reads its log"
}

# --- (g)/(h) dead endpoints and torn-down worktrees --------------------------

test_dead_window_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case dead-window)
  make_repo_on_branch "$d/wt" fm/feat-dead
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead.meta" "window=fm:fm-feat-dead" "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-dead.status"
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead)
  assert_contains "$out" "state: unknown" "dead window -> unknown"
  assert_contains "$out" "source: none" "dead window -> none source"
  assert_not_contains "$out" "source: status-log" "dead window does not reuse stale log"
  pass "a dead endpoint ignores the stale status log"
}

test_no_backend_target_recorded() {
  reset_fakes
  local d; d=$(new_case no-target)
  make_repo_on_branch "$d/wt" fm/feat-nt
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-nt.meta" "worktree=$d/wt" "kind=ship"
  printf 'working: implementing\n' > "$d/state/feat-nt.status"
  local out; out=$(run_crew_state "$d" feat-nt)
  assert_contains "$out" "state: unknown" "a meta with no endpoint -> unknown"
  assert_contains "$out" "source: none" "a meta with no endpoint -> none source"
  pass "a meta with no recorded endpoint reports unknown"
}

test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torn-down)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-gone.meta" "window=fm:fm-feat-gone" "worktree=$d/no-such-wt" "kind=ship"
  local out; out=$(run_crew_state "$d" feat-gone)
  assert_contains "$out" "state: unknown" "torn-down worktree -> unknown"
  assert_contains "$out" "source: none" "torn-down worktree -> none source"
  pass "a torn-down worktree reports unknown"
}

test_missing_meta() {
  reset_fakes
  local d; d=$(new_case missing-meta)
  make_fakebin "$d" >/dev/null
  local out; out=$(run_crew_state "$d" nobody)
  assert_contains "$out" "state: unknown" "missing meta -> unknown"
  assert_contains "$out" "source: none" "missing meta -> none source"
  pass "missing meta reports unknown"
}

test_scout_reads_pane_and_log() {
  reset_fakes
  local d; d=$(new_case scout)
  mkdir -p "$d/wt"   # a scout's scratch worktree may sit at detached HEAD
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/probe.meta" "window=fm:fm-probe" "worktree=$d/wt" "kind=scout"
  FM_FAKE_BUSY=1
  local out; out=$(run_crew_state "$d" probe)
  assert_contains "$out" "state: working" "a busy scout reads working"
  assert_contains "$out" "source: pane" "a busy scout reads from the pane"
  FM_FAKE_BUSY=0
  printf 'done: report written\n' > "$d/state/probe.status"
  out=$(run_crew_state "$d" probe)
  assert_contains "$out" "state: done" "an idle scout falls back to its log"
  pass "kind=scout reads the same pane-then-log sources"
}

# --- (i) the watcher's absorb predicate, end to end --------------------------
# Same two directions as before, now over the real helper: a busy crew is absorbed,
# a genuinely stopped one still surfaces (the safety property must never widen).

test_provably_working_via_busy_pane() {
  reset_fakes
  local d; d=$(new_case provably-working-busy)
  make_repo_on_branch "$d/wt" fm/feat-provable
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-provable.meta" "window=fm:fm-feat-provable" "worktree=$d/wt" "kind=ship"
  FM_FAKE_BUSY=1
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-provable \
    || fail "a busy crew was not treated as provably working"
  pass "crew_is_provably_working absorbs a crew with a busy pane"
}

test_not_provably_working_when_stopped() {
  reset_fakes
  local d; d=$(new_case provably-working-stopped)
  make_repo_on_branch "$d/wt" fm/feat-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-stopped.meta" "window=fm:fm-feat-stopped" "worktree=$d/wt" "kind=ship"
  # The crew stopped its turn: the pane is idle, and a leftover `working:` line in
  # the log is NOT positive evidence, so the wake must surface.
  printf 'working: implementing\n' > "$d/state/feat-stopped.status"
  FM_FAKE_BUSY=0
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-stopped \
    && fail "a stopped crew with an idle pane and a stale working: line was treated as provably working"
  pass "crew_is_provably_working still surfaces a genuinely stopped crew (safety property preserved)"
}

# Usage error (no id) is the one non-zero exit.
test_usage_error() {
  reset_fakes
  local rc
  "$CREW_STATE" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  pass "usage error exits 2"
}

test_busy_pane_is_working
test_busy_pane_supersedes_stale_needs_decision
test_busy_pane_supersedes_stale_blocked
test_idle_pane_uses_log
test_idle_pane_maps_every_known_verb
test_idle_pane_uses_keyed_log
test_idle_pane_paused
test_idle_pane_custom_paused_verb
test_idle_secondmate_resolved_event_not_state
test_secondmate_skips_the_busy_check
test_dead_window_ignores_stale_status_log
test_no_backend_target_recorded
test_torn_down_worktree
test_missing_meta
test_scout_reads_pane_and_log
test_provably_working_via_busy_pane
test_not_provably_working_when_stopped
test_usage_error

echo "all fm-crew-state tests passed"
