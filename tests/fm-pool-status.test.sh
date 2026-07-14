#!/usr/bin/env bash
# Tests for bin/fm-pool-status.sh - noticing a silently shrinking treehouse pool.
#
# THE INCIDENT (2026-07-14): the box rebooted mid-task three times. Each crash
# left the crew's slot DIRTY. `treehouse get` skips a dirty slot forever, and
# `treehouse prune` refuses to reclaim it - so the pool silently shrank, nothing
# noticed, and a human found it by looking. These tests pin the noticing.
#
# The load-bearing property is NOT the detection - it is the REFUSAL to sweep. A
# dirty slot may hold a dead crew's unlanded work (today's did, and it was
# salvaged and shipped), so this script reports and never discards. Case (b) is
# the one that matters.
#
#   (a) a healthy pool          -> silent (bootstrap's convention: silence = good)
#   (b) a dirty slot with work  -> REPORTED with its evidence, and NOT discarded
#   (c) the report carries both an inspect command and an explicit discard command
#   (d) a stale fm-warm lease   -> reported as safely releasable
#   (e) a live warmer's lease   -> NOT reported (it is doing its job)
#   (f) an orphaned slot (owner pid dead) -> reported, inspect-first
#   (g) a blocked warm (disk budget) surfaces at session start
#   (h) bootstrap prints the pool lines
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

STATUS="$ROOT/bin/fm-pool-status.sh"
TMP_ROOT=$(fm_test_tmproot fm-pool-status)
mkdir -p "$TMP_ROOT"

new_case() {  # <name> -> echoes the case dir
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/home/state" "$case_dir/home/config" "$case_dir/home/projects" \
           "$case_dir/fakebin" "$case_dir/th-root"
  fm_git_init_commit "$case_dir/home/projects/proj"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status) cat "${TH_STATUS:?}" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  : > "$case_dir/status.txt"
  printf '%s\n' "$case_dir"
}

# A slot that a crashed crew left behind: a real worktree, with real uncommitted
# work in it - the thing a reflexive sweep would destroy.
dirty_slot() {  # <case-dir> -> echoes the slot path
  local case_dir=$1 slot="$1/th-root/pool/1/proj"
  mkdir -p "$(dirname "$slot")"
  git -C "$case_dir/home/projects/proj" worktree add -q --detach "$slot" 2>/dev/null
  printf 'the dead crew unsaved work\n' > "$slot/rescue-me.txt"
  printf '%s\n' "$slot"
}

run_status() {  # <case-dir>
  ( cd "$1" || exit 1
    env PATH="$1/fakebin:$PATH" \
      TH_STATUS="$1/status.txt" \
      FM_ROOT_OVERRIDE="$ROOT" \
      FM_HOME="$1/home" \
      FM_STATE_OVERRIDE="$1/home/state" \
      FM_PROJECTS_OVERRIDE="$1/home/projects" \
      FM_TREEHOUSE_ROOT="$1/th-root" \
      "$STATUS" )
}

# --- (a) a healthy pool says nothing -----------------------------------------
C=$(new_case a)
printf '1     available    /pool/1/proj\n2     in-use       /pool/2/proj\n' > "$C/status.txt"
out=$(run_status "$C")
[ -z "$out" ] || fail "(a) a healthy pool must be silent, got: $out"
pass "(a) a healthy pool is silent"

# --- (b) THE INCIDENT: a dirty slot with real work is reported, never swept ---
C=$(new_case b)
slot=$(dirty_slot "$C")
printf '1     dirty        %s\n' "$slot" > "$C/status.txt"
out=$(run_status "$C")
assert_contains "$out" "POOL_SLOT" "(b) a dirty slot must be reported"
assert_contains "$out" "is DIRTY" "(b) it must be named as dirty"
assert_contains "$out" "skips it forever" "(b) it must say why this silently shrinks the pool"
assert_contains "$out" "uncommitted file" "(b) it must report the evidence of unlanded work"
# The property that matters: the work is STILL THERE afterwards.
assert_present "$slot/rescue-me.txt" "(b) a dead crew's unlanded work must NOT be discarded"
pass "(b) a dirty slot holding a dead crew's work is reported, and the work survives"

# --- (c) the report is actionable: inspect first, discard only deliberately ----
assert_contains "$out" "git -C $slot status" "(c) must print how to INSPECT the work first"
assert_contains "$out" "DISCARDS" "(c) the reclaim command must be labelled destructive"
assert_contains "$out" "treehouse destroy $slot --include-unlanded --yes" "(c) must print the exact reclaim command"
pass "(c) the report says how to inspect, and marks the reclaim as destructive"

# --- (d) a stale warm lease: reserved forever by a warmer that died -----------
C=$(new_case d)
printf '1     leased       /pool/1/proj  (held by fm-warm-proj)\n' > "$C/status.txt"
out=$(run_status "$C")   # no live warmer holds the pool lock
assert_contains "$out" "no live warmer" "(d) a lease with no live warmer must be reported"
assert_contains "$out" "treehouse return /pool/1/proj" "(d) must print the safe release command"
assert_contains "$out" "holds no work" "(d) must say the release is safe, unlike a dirty slot"
pass "(d) a warm lease orphaned by a dead warmer is reported as safely releasable"

# --- (e) a LIVE warmer's lease is its job, not a fault ------------------------
C=$(new_case e)
printf '1     leased       /pool/1/proj  (held by fm-warm-proj)\n' > "$C/status.txt"
key=$(printf '%s' "$(cd "$C/home/projects/proj" && pwd -P)" | cksum | awk '{print $1}')
mkdir -p "$C/th-root/.fm-warm-locks/proj-$key"
printf '%s\n' "$$" > "$C/th-root/.fm-warm-locks/proj-$key/pid"   # a LIVE warmer
out=$(run_status "$C")
[ -z "$out" ] || fail "(e) a live warmer mid-install must not be reported as a fault, got: $out"
pass "(e) a slot leased by a live warmer is not reported - it is doing its job"

# --- (f) an orphaned slot: treehouse still reserves it, its owner is gone -----
if command -v jq >/dev/null 2>&1; then
  C=$(new_case f)
  slot="$C/th-root/pool/1/proj"          # the pool dir must be derivable from the slot path
  mkdir -p "$slot"
  printf '1     in-use       %s\n' "$slot" > "$C/status.txt"
  cat > "$C/th-root/pool/treehouse-state.json" <<EOF
{ "worktrees": [ { "name": "1", "path": "$slot", "owner_pid": 999999 } ] }
EOF
  out=$(run_status "$C")
  assert_contains "$out" "ORPHANED" "(f) a slot whose owner pid is gone must be reported"
  assert_contains "$out" "inspect it before reclaiming" "(f) an orphan may hold work: inspect, never sweep"
  pass "(f) an orphaned slot (owner pid dead) is reported, inspect-first"
else
  pass "(f) skipped: jq not installed"
fi

# --- (g) a blocked warm surfaces at session start -----------------------------
C=$(new_case g)
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
key=$(printf '%s' "$(cd "$C/home/projects/proj" && pwd -P)" | cksum | awk '{print $1}')
printf 'disk budget reached: pool uses 19.6 GB and the next slot needs about 2.8 GB, over the 20.0 GB budget\n' \
  > "$C/home/state/.pool-warm-blocked.proj-$key"
out=$(run_status "$C")
assert_contains "$out" "POOL_BUDGET" "(g) a stopped warm must surface at session start"
assert_contains "$out" "19.6 GB" "(g) it must carry the real numbers"
pass "(g) a warm stopped by the disk budget surfaces at session start with its numbers"

# --- (h) bootstrap prints the pool lines -------------------------------------
C=$(new_case h)
slot=$(dirty_slot "$C")
printf '1     dirty        %s\n' "$slot" > "$C/status.txt"
out=$( cd "$C" && env PATH="$C/fakebin:$PATH" TH_STATUS="$C/status.txt" \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$C/home" \
  FM_STATE_OVERRIDE="$C/home/state" FM_CONFIG_OVERRIDE="$C/home/config" \
  FM_PROJECTS_OVERRIDE="$C/home/projects" FM_TREEHOUSE_ROOT="$C/th-root" \
  FM_BOOTSTRAP_DETECT_ONLY=1 \
  "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null )
assert_contains "$out" "POOL_SLOT" "(h) bootstrap must surface an unusable pool slot"
assert_present "$slot/rescue-me.txt" "(h) bootstrap must never discard the work either"
pass "(h) bootstrap surfaces the pool diagnostic, and discards nothing"
