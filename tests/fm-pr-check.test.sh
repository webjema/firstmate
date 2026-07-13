#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh: recording the PR into task meta, and the CI-aware
# poll it arms at state/<id>.check.sh.
#
# The poll is firstmate's own CI awareness (it replaced a grep over another tool's
# log prose), and it must honor the watcher's check contract exactly: print ONE
# line only when firstmate should WAKE, print NOTHING otherwise.
#
# Matrix (the poll is executed exactly as bin/fm-watch.sh runs it: `bash <check>`):
#   (a) pr= and pr_head= are recorded into meta, and the check is armed
#   (b) checks pending          -> SILENT (CI is still running)
#   (c) checks green, unmerged  -> SILENT (waiting on the captain's merge)
#   (d) no checks reported      -> SILENT (nothing to fail)
#   (e) a check FAILED          -> wakes with "checks failed"
#   (f) the same failure again  -> SILENT (one wake per PR head, not every poll)
#   (g) a NEW head still failing-> wakes again (a fix round that failed again)
#   (h) PR merged               -> wakes with "merged" (teardown time)
#   (i) merged wins over failing checks
#   (j) gh missing or erroring  -> SILENT (never wake on a tool error)
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check)
URL='https://github.com/o/r/pull/7'

# A fake `gh` whose `pr view --json ... -q <expr>` answer is served verbatim from
# FM_FAKE_GH_LINE - the same three whitespace-separated fields the real gh -q
# expression emits ("<state> <headRefOid> <checks-verdict>"). FM_FAKE_GH_FAIL=1
# makes the call fail like an auth/network error.
make_fake_gh() {  # <dir> -> echoes fakebin path
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_GH_FAIL:-0}" = 1 ] && exit 1
for a in "$@"; do
  [ "$a" = headRefOid ] && { printf '%s\n' "${FM_FAKE_GH_HEAD:-deadbee}"; exit 0; }
done
printf '%s\n' "${FM_FAKE_GH_LINE:-}"
exit 0
SH
  chmod +x "$fb/gh"
  printf '%s\n' "$fb"
}

new_case() {  # <name> -> echoes case dir with state/ and a worktree
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state" "$d/wt"
  fm_write_meta "$d/state/t1.meta" "window=fm:fm-t1" "worktree=$d/wt" "kind=ship" "mode=PR"
  make_fake_gh "$d" >/dev/null
  printf '%s\n' "$d"
}

arm() {  # <case-dir>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$PR_CHECK" t1 "$URL" >/dev/null
}

# Run the armed check the way bin/fm-watch.sh's run_check does.
poll() {  # <case-dir>
  PATH="$1/fakebin:$PATH" bash "$1/state/t1.check.sh" 2>/dev/null
}

test_records_pr_and_arms_check() {
  local d out
  d=$(new_case record)
  export FM_FAKE_GH_HEAD=abc123 FM_FAKE_GH_LINE='OPEN abc123 pending'
  out=$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" "$PR_CHECK" t1 "$URL")
  assert_contains "$out" "armed:" "arming did not report itself"
  assert_grep "pr=$URL" "$d/state/t1.meta" "pr= was not recorded in meta"
  assert_grep "pr_head=abc123" "$d/state/t1.meta" "pr_head= was not recorded in meta"
  assert_present "$d/state/t1.check.sh" "the merge/CI poll was not armed"
  # Arming twice must not duplicate the meta lines.
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" "$PR_CHECK" t1 "$URL" >/dev/null
  [ "$(grep -c "^pr=$URL$" "$d/state/t1.meta")" -eq 1 ] || fail "re-arming duplicated pr="
  pass "fm-pr-check records pr=/pr_head= and arms the poll (idempotently)"
}

# The silence contract: while CI is running, green-but-unmerged, or reporting no
# checks at all, firstmate must not be woken.
test_silent_while_not_actionable() {
  local d out verdict
  d=$(new_case silent)
  export FM_FAKE_GH_HEAD=abc123
  export FM_FAKE_GH_LINE='OPEN abc123 pending'
  arm "$d"
  for verdict in pending pass none; do
    FM_FAKE_GH_LINE="OPEN abc123 $verdict"
    out=$(poll "$d")
    [ -z "$out" ] || fail "the poll woke firstmate on a non-actionable state ($verdict): $out"
  done
  pass "the poll stays silent while checks run, sit green-unmerged, or are absent"
}

test_failed_checks_wake_once_per_head() {
  local d out
  d=$(new_case failed)
  export FM_FAKE_GH_HEAD=abc123
  export FM_FAKE_GH_LINE='OPEN abc123 fail'
  arm "$d"

  out=$(poll "$d")
  assert_contains "$out" "checks failed" "a failing check did not wake firstmate"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "the poll printed more than one line"

  # Same head, still failing: already reported, so stay silent.
  out=$(poll "$d")
  [ -z "$out" ] || fail "an already-reported failure re-woke firstmate: $out"

  # A fix round pushed a NEW head that still fails: that is new news.
  FM_FAKE_GH_LINE='OPEN def456 fail'
  out=$(poll "$d")
  assert_contains "$out" "checks failed" "a failure on a new PR head did not wake firstmate"
  pass "failed checks wake firstmate once per PR head, and again on a new head"
}

test_merged_wakes() {
  local d out
  d=$(new_case merged)
  export FM_FAKE_GH_HEAD=abc123
  export FM_FAKE_GH_LINE='OPEN abc123 pending'
  arm "$d"
  FM_FAKE_GH_LINE='MERGED abc123 pass'
  out=$(poll "$d")
  [ "$out" = "merged" ] || fail "a merged PR did not wake with 'merged' (got: $out)"
  # Merge is terminal news even if the last CI verdict was red.
  FM_FAKE_GH_LINE='MERGED abc123 fail'
  out=$(poll "$d")
  [ "$out" = "merged" ] || fail "merged must win over a failing check verdict (got: $out)"
  pass "a merged PR wakes firstmate, and merged outranks a red verdict"
}

test_tool_error_is_silent() {
  local d out
  d=$(new_case gh-error)
  export FM_FAKE_GH_HEAD=abc123
  export FM_FAKE_GH_LINE='OPEN abc123 fail'
  arm "$d"
  out=$(FM_FAKE_GH_FAIL=1 poll "$d")
  [ -z "$out" ] || fail "a failing gh call woke firstmate: $out"
  # gh missing entirely (empty PATH except coreutils) must also be silent.
  out=$(PATH="/nonexistent" bash "$d/state/t1.check.sh" 2>/dev/null)
  [ -z "$out" ] || fail "a missing gh woke firstmate: $out"
  pass "a gh error or a missing gh never wakes firstmate"
}

test_records_pr_and_arms_check
test_silent_while_not_actionable
test_failed_checks_wake_once_per_head
test_merged_wakes
test_tool_error_is_silent

echo "all fm-pr-check tests passed"
