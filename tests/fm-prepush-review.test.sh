#!/usr/bin/env bash
# Tests for the pre-push review gate (AGENTS.md section 6, "Review before the PR").
#
# The contract under test: a PR-mode ship crewmate pushes its branch, opens NO PR,
# and signals `review-ready:`. Firstmate reviews the pushed branch, and only an
# approval turns it into a PR. Three things must hold for that loop to work at all:
#
#   1. `review-ready:` wakes firstmate. It is captain-relevant (the crew is BLOCKED on
#      firstmate), and absorbing it would strand a finished crew forever. Relevance is
#      anchored to the leading verb, so a prose mention of review-readiness inside a
#      `working:` line must NOT escalate.
#   2. The ship brief actually tells the crew to stop at the push - a scaffold that
#      still says "open a PR" would silently keep the old loop.
#   3. bin/fm-review-diff.sh works on a pushed branch with NO pr= recorded, since that
#      is now the PRIMARY review path rather than an edge case.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-prepush-review-tests)

# --- 1. review-ready is a captain-relevant verb ------------------------------

test_review_ready_is_captain_relevant() {
  # shellcheck source=bin/fm-classify-lib.sh
  . "$ROOT/bin/fm-classify-lib.sh"

  status_is_captain_relevant 'review-ready: branch fm/task-x1 pushed, no PR' \
    || fail "review-ready: must be captain-relevant - the crew is blocked on firstmate's review"

  # A crew whose harness decorates the verb is still review-ready (same rule the
  # other verbs get via status_normalize_verb).
  status_is_captain_relevant '- **Review-Ready**: pushed, no PR' \
    || fail "a decorated/capitalized review-ready verb must still escalate"

  # ...but relevance stays anchored to the LEADING verb. Prose is never scanned.
  ! status_is_captain_relevant 'working: getting the branch review-ready' \
    || fail "a working: line mentioning review-ready in prose must not escalate"

  case " $FM_CLASSIFY_CAPTAIN_VERBS " in
    *' review-ready '*) : ;;
    *) fail "review-ready must be in FM_CLASSIFY_CAPTAIN_VERBS (the one owner of the verb set)" ;;
  esac

  pass "review-ready: is a captain-relevant verb, anchored to the leading verb"
}

# --- 2. the PR-mode ship brief stops at the push -----------------------------

scaffold_pr_brief() {
  local home=$1 id=$2
  mkdir -p "$home/data" "$home/state" "$home/projects/demo"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    "$ROOT/bin/fm-brief.sh" "$id" demo >/dev/null
  printf '%s\n' "$home/data/$id/brief.md"
}

test_ship_brief_signals_review_ready_and_opens_no_pr() {
  local home brief body
  home="$TMP_ROOT/brief-home"
  brief=$(scaffold_pr_brief "$home" task-x1)
  body=$(cat "$brief")

  assert_contains "$body" 'review-ready: branch fm/task-x1 pushed, no PR' \
    "the ship brief must tell the crew the exact review-ready line to append"
  assert_contains "$body" 'Push your branch. Open NO PR.' \
    "the ship brief must tell the crew to push but not open a PR"
  assert_contains "$body" 'Never open a PR before firstmate approves' \
    "rule 1 must forbid opening a PR before firstmate's review"
  assert_contains "$body" 'Fix them IN PLACE on the same branch' \
    "the ship brief must route review findings to an in-place fix, not a new PR round"
  assert_contains "$body" 'done: PR {url}' \
    "an approved crew still reports done: PR <url> once it opens the PR"

  # The old loop's instruction must be GONE: nothing may tell the crew to push and
  # open a PR in the same breath.
  assert_not_contains "$body" 'Push your branch and open a PR' \
    "the pre-review push-and-open-PR instruction must be gone from the ship brief"

  pass "the PR-mode ship brief pushes, signals review-ready, and opens no PR"
}

test_local_only_brief_is_unchanged_by_the_gate() {
  local home brief body
  home="$TMP_ROOT/local-only-home"
  mkdir -p "$home/data" "$home/state" "$home/projects/demo"
  printf -- '- demo [local-only] - a local-only project (added 2026-07-14)\n' \
    > "$home/data/projects.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    "$ROOT/bin/fm-brief.sh" task-l1 demo >/dev/null
  brief="$home/data/task-l1/brief.md"
  body=$(cat "$brief")

  # local-only never had a PR to review before, so its contract is untouched: it
  # still stops at "ready in branch" and never pushes.
  assert_contains "$body" 'done: ready in branch fm/task-l1' \
    "local-only must still report ready in branch"
  assert_not_contains "$body" 'review-ready:' \
    "local-only has no PR to gate, so it must not gain the review-ready verb"
  pass "the local-only brief is unaffected by the pre-push review gate"
}

# --- 3. review-diff works on a pushed branch with no PR ----------------------

test_review_diff_reviews_a_pushed_branch_with_no_pr() {
  local case_dir out err
  case_dir="$TMP_ROOT/pushed-no-pr"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-p1 "$case_dir/wt" main

  # The new primary review path: the crew committed AND PUSHED its branch, and
  # opened no PR - so nothing recorded pr= in the meta.
  printf 'crew-change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "the crew's change"
  git -C "$case_dir/wt" push -q origin fm/task-p1

  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-p1.meta" \
    "window=fm-task-p1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-review-diff.sh" task-p1 --full 2> "$case_dir/stderr")
  err=$(cat "$case_dir/stderr")

  assert_contains "$out" 'diff base: origin/main' \
    "a pushed no-PR branch must still be reviewed against the authoritative remote base"
  assert_contains "$out" '+crew-change' \
    "the review diff must show the pushed branch's code with no PR recorded"
  assert_not_contains "$err" 'warning: PR head unavailable' \
    "no pr= is recorded, so there is no PR head to warn about"
  pass "fm-review-diff reviews a pushed branch that has no PR - the new primary path"
}


# --- 4. review-ready must never be LOST ---------------------------------------

test_review_ready_opens_a_durable_decision_until_the_pr_exists() {
  # shellcheck source=bin/fm-classify-lib.sh
  . "$ROOT/bin/fm-classify-lib.sh"
  local dir open
  dir="$TMP_ROOT/open-decisions"
  mkdir -p "$dir"

  # A review-ready crew has STOPPED by contract, so it will never append another line.
  # Every per-wake backstop is one-shot (signal needs a status change, stale needs a
  # changing pane hash, the CI poll needs a PR that does not exist yet), so if firstmate
  # drains that single wake and then restarts or simply moves on, NOTHING raises it again:
  # the crew idles forever and its branch sits on the remote with no PR. That is strictly
  # worse than a lost `done:`, which at least left a visible PR behind. A durable open
  # decision is what makes the heartbeat keep re-raising it.
  printf 'working: building\nreview-ready: branch fm/task-x1 pushed, no PR\n' > "$dir/a.status"
  open=$(status_open_decisions "$dir/a.status")
  assert_contains "$open" 'review-ready' \
    "a review-ready crew must stay OPEN, or nothing will ever raise it again"

  # A later unrelated line must not mask it - that is the whole point of the durable set.
  printf 'working: fixing review findings\n' >> "$dir/a.status"
  open=$(status_open_decisions "$dir/a.status")
  assert_contains "$open" 'review-ready' "an unrelated later line silently closed the review"

  # Re-signalling after fixing findings supersedes rather than stacks.
  printf 'review-ready: findings fixed, pushed again\n' >> "$dir/a.status"
  open=$(status_open_decisions "$dir/a.status")
  [ "$(printf '%s' "$open" | grep -c review-ready)" -eq 1 ] \
    || fail "a re-signalled review-ready stacked instead of superseding"

  # ONLY the crew's own done: PR <url> closes it - the review is over exactly when the
  # approved PR exists.
  printf 'done: PR https://github.com/o/r/pull/9\n' >> "$dir/a.status"
  open=$(status_open_decisions "$dir/a.status")
  assert_not_contains "$open" 'review-ready' "done: PR <url> must close the review-ready"

  # ...and done: must close NOTHING else. A crew reporting done while a needs-decision is
  # still open must not have that decision silently cleared.
  printf 'needs-decision: which shape?\ndone: PR https://github.com/o/r/pull/9\n' > "$dir/b.status"
  open=$(status_open_decisions "$dir/b.status")
  assert_contains "$open" 'needs-decision' \
    "done: closed an open captain decision - the exact masking this set exists to prevent"

  pass "review-ready opens a durable decision that only the crew's own done: PR closes"
}

# A review-ready crew's terminal genuinely can vanish while the crew is by-design
# parked on the remote waiting for firstmate (it did, to PR #5's own crew). When the
# window is GONE, fm-crew-state.sh must still read review-ready from the log - that is
# the one terminal verb meaning "stopped ON PURPOSE, waiting on firstmate", so a
# missing window is EXPECTED for it, not a dead-crew fault. Reporting `unknown` instead
# is what AGENTS.md section 7 reads as a dead or wedged crew and routes to
# stuck-crewmate-recovery, interrupting or relaunching the very crew patiently waiting.
#
# This is exercised HERMETICALLY with a fake `tmux` that always reports the window
# missing (the same fake-driver pattern as tests/fm-crew-state.test.sh). Probing the
# REAL tmux is what made this environment-dependent before: `tmux display-message -t`
# loose-resolves to exit 0 for ANY target when a client is attached (a crew's own pane,
# 8-core dev box), so the target-gone branch was never taken there, yet on CI with no
# attached client the same probe fails and the branch IS taken. The fake forces the
# gone branch on every box, so this test proves the fix rather than the environment.
crew_state_with_missing_window() {  # <case-dir> <id> -> stdout of fm-crew-state.sh
  local dir=$1 id=$2 fb="$1/fakebin"
  mkdir -p "$fb"
  # A `tmux` that always fails: the window is unconditionally gone.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fb/tmux"
  chmod +x "$fb/tmux"
  PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/fm-crew-state.sh" "$id" 2>&1 || true
}

test_crew_state_knows_review_ready_and_does_not_call_it_unknown() {
  local dir out
  dir="$TMP_ROOT/crew-state"
  mkdir -p "$dir/state"
  fm_write_meta "$dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$dir" "project=$dir"

  # A parked review-ready crew whose window is gone still reads review-ready.
  printf 'review-ready: branch fm/task-x1 pushed, no PR\n' > "$dir/state/task-x1.status"
  out=$(crew_state_with_missing_window "$dir" task-x1)
  assert_contains "$out" 'review-ready' "fm-crew-state.sh does not know the review-ready verb"
  assert_not_contains "$out" 'state: unknown' \
    "a review-ready crew reported as unknown would be treated as wedged and interrupted"

  # ...but the dead-crew guard must NOT widen: a genuinely gone crew whose last line is
  # any OTHER verb stays unknown, so a stale log is never trusted for a vanished crew.
  printf 'working: implementing\n' > "$dir/state/task-x1.status"
  out=$(crew_state_with_missing_window "$dir" task-x1)
  assert_contains "$out" 'state: unknown' \
    "a gone crew whose last line is not review-ready must stay unknown (dead-crew guard)"
  assert_not_contains "$out" 'review-ready' \
    "review-ready must be the ONLY verb read from the log when the window is gone"

  pass "fm-crew-state.sh reports review-ready (not unknown) for a parked crew whose window is gone, but no other verb"
}

test_review_ready_is_captain_relevant
test_review_ready_opens_a_durable_decision_until_the_pr_exists
test_crew_state_knows_review_ready_and_does_not_call_it_unknown
test_ship_brief_signals_review_ready_and_opens_no_pr
test_local_only_brief_is_unchanged_by_the_gate
test_review_diff_reviews_a_pushed_branch_with_no_pr
