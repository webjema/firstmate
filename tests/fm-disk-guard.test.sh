#!/usr/bin/env bash
# Tests for bin/fm-disk-guard.sh: the janitor that fires on disk pressure rather
# than on a lifecycle event.
#
# Load-bearing behaviors:
#   (a) a healthy disk produces no action and no output
#   (b) the tier is whichever of free-GB and used-% reads worse, so a huge disk at a
#       high percentage stays ok and a small disk with little free space does not
#   (c) an unparseable df takes NO action - the guard fails closed rather than
#       comparing thresholds against a garbage number
#   (d) --dry-run and --report-only delete nothing
#   (e) a leased worktree is never destroyed, only reported, with the release command
#   (f) an unleased landed worktree IS destroyed at the critical tier
#   (g) an unanswerable lease state reads as HELD, not as free
#   (h) the scratch window is only tightened when live sessions could be enumerated;
#       a failed probe falls back to the reaper's own default
#   (i) FM_DISK_CACHES gates each cache family, and an empty value disables all
#   (j) bad arguments are refused with exit 2; everything else exits 0
#   (k) cdk synth staging dirs past the age window are swept, and the window's near
#       side is spared exactly - a 3-day-old dir survives a 3-day window, so the
#       recently-finished work a user might still want to inspect is never taken
#
# (c), (g) and (h) are the fail-closed rails. Each drives the guard through a stub
# that makes one signal unavailable and asserts the guard DECLINES to act, because
# every one of them guards an `rm -rf` and a wrong "safe to delete" is unrecoverable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-disk-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-disk-guard-tests)

# Point the cdk sweep at an empty sandbox for EVERY case in this file, not just the
# cdk ones. Several cases below drive the guard at a real sweeping tier with no
# --dry-run, and the sweep's root defaults to the actual /tmp - so without this line
# running the suite deletes the developer's own cdk staging dirs. That is not
# hypothetical: it happened on 2026-08-17, during a mutation check that widened the
# age window, and it cost ~11.5k real directories.
# It is exported once here rather than passed per case on purpose. A test that has
# to REMEMBER to sandbox an `rm -rf` is one edit away from not doing it, and the
# blast radius is outside the test tree where no fixture can undo it. Cases that
# need staging dirs to act on override it with their own root.
export FM_DISK_TMP_ROOT="$TMP_ROOT/tmp-sandbox"
mkdir -p "$FM_DISK_TMP_ROOT"

# Put a stub `df` first on PATH that reports fixed numbers, so a test can place the
# box at any occupancy without a real filesystem of that size. The POSIX -Pk layout
# is what the guard parses, so the stub reproduces exactly that: header, then one
# line of Filesystem/1024-blocks/Used/Available/Capacity/Mounted-on.
make_df_stub() {  # <name> <avail-kb> <used-pct>
  local name=$1 avail=$2 pct=$3 dir
  dir="$TMP_ROOT/stub-$name"
  mkdir -p "$dir"
  cat > "$dir/df" <<SH
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted-on"
echo "/dev/root 161061273 1 $avail ${pct}% /"
SH
  chmod +x "$dir/df"
  printf '%s\n' "$dir"
}

# A df that answers nothing at all: the shape of failure that makes every threshold
# comparison arbitrary.
make_broken_df_stub() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/stub-$name"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/df"
  chmod +x "$dir/df"
  printf '%s\n' "$dir"
}

# Build a fake treehouse root holding one pool with one worktree whose branch is
# committed, pushed to a local "remote", and clean - i.e. everything wt_is_landed
# checks except the merged-PR verdict, which the gh stub below supplies.
make_treehouse() {  # <name> <leased true|false>
  local name=$1 leased=$2 root pool wt remote
  root="$TMP_ROOT/$name/.treehouse"
  pool="$root/proj-abc123"
  wt="$pool/1/proj"
  remote="$TMP_ROOT/$name/remote.git"
  mkdir -p "$wt"
  git init --quiet --bare "$remote"
  git init --quiet "$wt"
  git -C "$wt" config user.email t@example.com
  git -C "$wt" config user.name test
  git -C "$wt" config commit.gpgsign false
  echo hello > "$wt/f"
  git -C "$wt" add f
  git -C "$wt" commit --quiet -m "landed work"
  git -C "$wt" branch -M feat/landed
  git -C "$wt" remote add origin "$remote"
  git -C "$wt" push --quiet -u origin feat/landed
  cat > "$pool/treehouse-state.json" <<JSON
{"worktrees":[{"name":"1","path":"$wt","leased":$leased}]}
JSON
  printf '%s\n' "$root"
}

# Stub gh + treehouse. gh reports the branch as merged; treehouse records each
# destroy into a log instead of deleting, so a test can assert on intent without
# needing the real tool. Echoes the fakebin dir.
make_tool_stubs() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/stub-$name"
  mkdir -p "$dir"
  cat > "$dir/gh" <<'SH'
#!/usr/bin/env bash
# Only answers the one query the guard makes: how many merged PRs for this head.
echo 1
SH
  # The stub logs every invocation AND, for a destroy, actually removes the target -
  # because the guard verifies the directory is gone before it reports a
  # reclamation, so a stub that only logs would make a working guard look broken.
  cat > "$dir/treehouse" <<SH
#!/usr/bin/env bash
echo "\$@" >> "$dir/treehouse.log"
if [ "\$1" = destroy ] && [ -d "\$2" ]; then rm -rf -- "\$2"; fi
exit 0
SH
  cat > "$dir/jq" <<'SH'
#!/usr/bin/env bash
# Minimal jq shim: the guard asks for .leased and .owner_pid of a matching path.
# Delegating to a real jq is preferred when one exists.
real=$(PATH=/usr/bin:/bin command -v jq 2>/dev/null)
[ -n "$real" ] && exec "$real" "$@"
exit 1
SH
  chmod +x "$dir/gh" "$dir/treehouse" "$dir/jq"
  printf '%s\n' "$dir"
}

test_healthy_disk_is_silent() {
  local stub out
  stub=$(make_df_stub healthy 104857600 40)   # 100G free, 40% used
  out=$(PATH="$stub:$PATH" "$GUARD" 2>&1) || fail "guard exited non-zero on a healthy disk"
  [ -z "$out" ] || fail "guard was not silent on a healthy disk: $out"
  out=$(PATH="$stub:$PATH" "$GUARD" --verbose 2>&1)
  assert_contains "$out" "ok -" "--verbose still reports the healthy tier"
  pass "a healthy disk produces no action and no output"
}

test_tier_takes_the_worse_of_the_two_signals() {
  local stub out
  # A big disk at a high percentage: 92% used but 300G free. Percentage alone would
  # call this critical; the free-space floor says there is plenty of room.
  stub=$(make_df_stub bigdisk 314572800 92)
  out=$(FM_DISK_CRITICAL_USED_PCT=95 FM_DISK_WARN_USED_PCT=99 PATH="$stub:$PATH" "$GUARD" --verbose 2>&1)
  assert_contains "$out" "ok -" "a big disk with room to spare stays ok"
  # A small disk with little free space: only 5G free though just 60% used.
  stub=$(make_df_stub smalldisk 5242880 60)
  out=$(PATH="$stub:$PATH" "$GUARD" --report-only 2>&1)
  assert_contains "$out" "critical -" "a low absolute free-space floor fires regardless of percentage"
  pass "the tier is whichever of free-GB and used-% reads worse"
}

test_unmeasurable_disk_takes_no_action() {
  local stub out
  stub=$(make_broken_df_stub nodf)
  out=$(PATH="$stub:$PATH" "$GUARD" 2>&1) || fail "guard exited non-zero when df failed"
  assert_contains "$out" "cannot measure free space" "the refusal names the reason"
  assert_contains "$out" "taking no action" "the refusal says nothing was done"
  assert_not_contains "$out" "reclaimed" "nothing was reclaimed on an unmeasurable disk"
  pass "an unparseable df fails closed and takes no action"
}

test_report_only_and_dry_run_delete_nothing() {
  local th tools out victim
  th=$(make_treehouse dryrun false)
  tools=$(make_tool_stubs dryrun)
  victim="$th/proj-abc123/1/proj"
  out=$(FM_TREEHOUSE_ROOT="$th" FM_DISK_CACHES='' PATH="$tools:$PATH" \
        "$GUARD" --tier critical --report-only 2>&1)
  [ -d "$victim" ] || fail "--report-only removed the worktree"
  [ -f "$tools/treehouse.log" ] && fail "--report-only invoked treehouse destroy"
  assert_contains "$out" "would destroy" "--report-only says what it would have done"
  pass "--dry-run and --report-only delete nothing"
}

test_leased_worktree_is_reported_never_destroyed() {
  local th tools out victim
  th=$(make_treehouse leased true)
  tools=$(make_tool_stubs leased)
  victim="$th/proj-abc123/1/proj"
  out=$(FM_TREEHOUSE_ROOT="$th" FM_DISK_CACHES='' PATH="$tools:$PATH" \
        "$GUARD" --tier critical 2>&1)
  [ -d "$victim" ] || fail "a LEASED worktree was destroyed"
  assert_contains "$out" "LEASED and were not touched" "the leased holdback is reported"
  assert_contains "$out" "--include-leased" "the report carries the command that would release it"
  grep -q "destroy $victim --yes" "$tools/treehouse.log" 2>/dev/null &&
    fail "treehouse destroy was invoked on a leased worktree"
  pass "a leased worktree is reported with its release command, never destroyed"
}

test_unleased_landed_worktree_is_destroyed_at_critical() {
  local th tools out victim
  th=$(make_treehouse unleased false)
  tools=$(make_tool_stubs unleased)
  victim="$th/proj-abc123/1/proj"
  out=$(FM_TREEHOUSE_ROOT="$th" FM_DISK_CACHES='' PATH="$tools:$PATH" \
        "$GUARD" --tier critical 2>&1)
  assert_contains "$out" "destroyed landed unleased worktree" "the destroy is reported"
  grep -q "destroy $victim" "$tools/treehouse.log" ||
    fail "treehouse destroy was not invoked for an unleased landed worktree"
  pass "an unleased landed worktree is destroyed at the critical tier"
}

test_unreadable_lease_state_reads_as_held() {
  local th tools out victim
  th=$(make_treehouse nostate false)
  tools=$(make_tool_stubs nostate)
  victim="$th/proj-abc123/1/proj"
  # Remove the state file: the guard can no longer prove the slot is free.
  rm -f "$th/proj-abc123/treehouse-state.json"
  out=$(FM_TREEHOUSE_ROOT="$th" FM_DISK_CACHES='' PATH="$tools:$PATH" \
        "$GUARD" --tier critical 2>&1)
  [ -d "$victim" ] || fail "an unprovable lease state was treated as free and destroyed"
  assert_contains "$out" "LEASED and were not touched" "the unprovable slot is held back"
  pass "an unanswerable lease state reads as held, not as free"
}

test_scratch_window_not_tightened_without_a_liveness_probe() {
  local stub out
  # A `ps` that answers nothing makes the live-session set unknowable. Tightening
  # the window on that would reap idle-but-live sessions, so the guard must not.
  stub="$TMP_ROOT/stub-nops"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stub/ps"
  chmod +x "$stub/ps"
  out=$(FM_DISK_CACHES='' FM_TREEHOUSE_ROOT="$TMP_ROOT/absent" PATH="$stub:$PATH" \
        "$GUARD" --tier critical --report-only 2>&1)
  assert_contains "$out" "cannot enumerate live sessions" "the failed probe is named"
  assert_contains "$out" "untouched >48h" "the window falls back to the reaper default"
  assert_not_contains "$out" "untouched >6h" "the window was not tightened on an unknown answer"
  pass "the scratch window is only tightened when live sessions could be enumerated"
}

test_cache_families_are_gated() {
  local out
  out=$(FM_DISK_CACHES='' FM_TREEHOUSE_ROOT="$TMP_ROOT/absent" \
        "$GUARD" --tier critical --report-only 2>&1)
  assert_not_contains "$out" "npm cache" "an empty FM_DISK_CACHES disables the npm family"
  assert_not_contains "$out" "playwright browsers" "an empty FM_DISK_CACHES disables playwright"
  pass "FM_DISK_CACHES gates each cache family"
}

# Build a tmp root holding cdk.out staging dirs at chosen ages, plus two decoys that
# the sweep must not touch: a directory whose name only starts the same way, and a
# plain file. Each dir gets a payload file so a half-delete is visible.
make_cdk_tmp() {  # <name> -> echoes the tmp root
  local name=$1 root d age
  root="$TMP_ROOT/$name"
  mkdir -p "$root"
  for age in 0 1 3 4 30; do
    d="$root/cdk.out-age$age"
    mkdir -p "$d"
    echo '{}' > "$d/manifest.json"
    touch -d "$age days ago" "$d/manifest.json" "$d"
  done
  mkdir -p "$root/cdk-not-out"
  touch -d "30 days ago" "$root/cdk-not-out"
  touch -d "30 days ago" "$root/cdk.out-a-file"
  printf '%s\n' "$root"
}

test_cdk_staging_dirs_older_than_the_window_are_swept() {
  local stub root out
  stub=$(make_df_stub cdk 21000000 86)
  root=$(make_cdk_tmp cdk-sweep)
  out=$(PATH="$stub:$PATH" FM_DISK_TMP_ROOT="$root" FM_TREEHOUSE_ROOT="$TMP_ROOT/absent" \
        "$GUARD" 2>&1)
  assert_contains "$out" "cdk synth staging dir" "the sweep reports what it reclaimed"
  [ -d "$root/cdk.out-age4" ] && fail "a 4-day-old staging dir survived the default 3-day window"
  [ -d "$root/cdk.out-age30" ] && fail "a 30-day-old staging dir survived"
  [ -d "$root/cdk.out-age0" ] || fail "today's staging dir was deleted"
  [ -d "$root/cdk.out-age1" ] || fail "a 1-day-old staging dir was deleted"
  [ -d "$root/cdk.out-age3" ] || fail "a 3-day-old staging dir was deleted; the window is >3d, not >=3d"
  [ -d "$root/cdk-not-out" ] || fail "a directory that merely shares a prefix was deleted"
  [ -f "$root/cdk.out-a-file" ] || fail "a plain file matching the name pattern was deleted"
  pass "cdk staging dirs past the window are swept and the 0-3 day window is spared"
}

test_cdk_sweep_respects_dry_run_and_the_age_knob() {
  local stub root out
  stub=$(make_df_stub cdkdry 21000000 86)
  root=$(make_cdk_tmp cdk-dry)
  out=$(PATH="$stub:$PATH" FM_DISK_TMP_ROOT="$root" FM_TREEHOUSE_ROOT="$TMP_ROOT/absent" \
        "$GUARD" --dry-run 2>&1)
  assert_contains "$out" "would reclaim 2 cdk synth staging dir" "--dry-run counts without deleting"
  [ -d "$root/cdk.out-age30" ] || fail "--dry-run deleted a staging dir"

  root=$(make_cdk_tmp cdk-age)
  out=$(PATH="$stub:$PATH" FM_DISK_TMP_ROOT="$root" FM_DISK_CDK_AGE_DAYS=10 \
        FM_TREEHOUSE_ROOT="$TMP_ROOT/absent" "$GUARD" 2>&1)
  [ -d "$root/cdk.out-age4" ] || fail "FM_DISK_CDK_AGE_DAYS=10 did not spare a 4-day-old dir"
  [ -d "$root/cdk.out-age30" ] && fail "FM_DISK_CDK_AGE_DAYS=10 did not sweep a 30-day-old dir"
  pass "the cdk sweep honours --dry-run and FM_DISK_CDK_AGE_DAYS"
}

test_cdk_sweep_is_silent_when_there_is_nothing_to_do() {
  local stub out
  stub=$(make_df_stub cdknone 21000000 86)
  mkdir -p "$TMP_ROOT/cdk-empty"
  out=$(PATH="$stub:$PATH" FM_DISK_TMP_ROOT="$TMP_ROOT/cdk-empty" \
        FM_TREEHOUSE_ROOT="$TMP_ROOT/absent" "$GUARD" 2>&1)
  assert_not_contains "$out" "cdk synth staging dir" "an empty tmp root produces no cdk line"
  pass "the cdk sweep says nothing when there is nothing to sweep"
}

test_bad_arguments_are_refused() {
  local rc=0
  "$GUARD" --tier nonsense >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "an invalid --tier was accepted (rc=$rc)"
  rc=0
  "$GUARD" --nope >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown flag was accepted (rc=$rc)"
  rc=0
  FM_DISK_WARN_FREE_GB=abc "$GUARD" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a non-numeric threshold was accepted (rc=$rc)"
  pass "bad arguments are refused with exit 2"
}

test_healthy_disk_is_silent
test_tier_takes_the_worse_of_the_two_signals
test_unmeasurable_disk_takes_no_action
test_report_only_and_dry_run_delete_nothing
test_leased_worktree_is_reported_never_destroyed
test_unleased_landed_worktree_is_destroyed_at_critical
test_unreadable_lease_state_reads_as_held
test_scratch_window_not_tightened_without_a_liveness_probe
test_cache_families_are_gated
test_cdk_staging_dirs_older_than_the_window_are_swept
test_cdk_sweep_respects_dry_run_and_the_age_knob
test_cdk_sweep_is_silent_when_there_is_nothing_to_do
test_bad_arguments_are_refused
