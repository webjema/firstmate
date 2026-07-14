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

# A lock is only honored as live when its pid is alive AND recorded on THIS boot:
# the lock outlives a reboot, so a bare pid can be recycled by an unrelated process
# (fm_pool_owner_alive).
current_boot() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    tr -d '[:space:]' < /proc/sys/kernel/random/boot_id
  elif [ -r /proc/stat ] && grep -q '^btime' /proc/stat 2>/dev/null; then
    sed -n 's/^btime[[:space:]]*//p' /proc/stat | head -n 1 | tr -d '[:space:]'
  else
    printf 'no-boot-id'
  fi
}
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

# give_pool_slot <case-dir>: a project with a pool HAS linked worktrees - that is
# what a slot is, and what fm_pool_has_slots reads (asking treehouse would create
# a pool). Cases that model a populated pool must therefore have a real one.
give_pool_slot() {
  local slot="$1/th-root/pool/0/proj"
  mkdir -p "$(dirname "$slot")"
  git -C "$1/home/projects/proj" worktree add -q --detach "$slot" 2>/dev/null
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
give_pool_slot "$C"
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

# --- (b2) a crew that COMMITTED on the detached HEAD still counts as work ------
# treehouse checks a slot out DETACHED. A crew that committed without branching
# leaves commits that `git log --branches` cannot see - so an evidence check built
# on --branches would report "nothing to lose" about a slot holding exactly the
# work we must not lose.
C=$(new_case b2)
# A real origin, so that ALREADY-LANDED commits are correctly excluded and the
# only unique commit is the one the dead crew made. Without a remote, everything
# looks unpushed and the check would pass for the wrong reason.
fm_git_add_origin "$C/home/projects/proj" "$C/origin.git"
git -C "$C/home/projects/proj" fetch -q origin
slot=$(dirty_slot "$C")
git -C "$slot" add rescue-me.txt
git -C "$slot" -c user.name=t -c user.email=t@t.t commit -qm 'the dead crew committed work'
printf 'and left this uncommitted too\n' > "$slot/also-dirty.txt"
printf '1     dirty        %s\n' "$slot" > "$C/status.txt"
out2=$(run_status "$C")
assert_contains "$out2" "1 unpushed commit" "(b2) a detached-HEAD commit is unlanded work and must be reported"
pass "(b2) work committed on a detached HEAD is still reported as unlanded"

# --- (c) the report is actionable: inspect first, discard only deliberately ----
assert_contains "$out2" "git -C $slot status" "(c) must print how to INSPECT the work first"
assert_contains "$out2" "DISCARDS" "(c) the reclaim command must be labelled destructive"
assert_contains "$out2" "treehouse destroy $slot --include-unlanded --yes" "(c) must print the exact reclaim command"
pass "(c) the report says how to inspect, and marks the reclaim as destructive"

# --- (d) a stale warm lease: reserved forever by a warmer that died -----------
C=$(new_case d)
give_pool_slot "$C"
printf '1     leased       /pool/1/proj  (held by fm-warm-proj)\n' > "$C/status.txt"
out=$(run_status "$C")   # no live warmer holds the pool lock
assert_contains "$out" "no live warmer" "(d) a lease with no live warmer must be reported"
assert_contains "$out" "treehouse return /pool/1/proj" "(d) must print the safe release command"
assert_contains "$out" "holds no work" "(d) must say the release is safe, unlike a dirty slot"
pass "(d) a warm lease orphaned by a dead warmer is reported as safely releasable"

# --- (e) a LIVE warmer's lease is its job, not a fault ------------------------
C=$(new_case e)
give_pool_slot "$C"
printf '1     leased       /pool/1/proj  (held by fm-warm-proj)\n' > "$C/status.txt"
# A LIVE warmer holds the pool lock the way the code takes it: an flock held by a
# live process (`exec sleep` so the pid we record is the one holding the fd).
key=$(printf '%s' "$(cd "$C/home/projects/proj" && pwd -P)" | cksum | awk '{print $1}')
base="$C/th-root/.fm-warm-locks/proj-$key"
mkdir -p "$(dirname "$base")"
( flock -x 9; exec sleep 60 ) 9>"$base.lock" &
holder=$!
i=0; while [ "$i" -lt 40 ] && flock -n "$base.lock" -c true 2>/dev/null; do sleep 0.1; i=$((i+1)); done
out=$(run_status "$C")
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[ -z "$out" ] || fail "(e) a live warmer mid-install must not be reported as a fault, got: $out"
pass "(e) a slot leased by a live warmer is not reported - it is doing its job"

# --- (f) an orphaned slot: treehouse still reserves it, its owner is gone -----
if command -v jq >/dev/null 2>&1; then
  C=$(new_case f)
  give_pool_slot "$C"
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
give_pool_slot "$C"
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

# --- (i) M6: a pool named only by a task META must be swept -------------------
# The sweep used to walk projects/* only. But a crewmate working on FIRSTMATE
# ITSELF has project=<the firstmate root>, which is NOT under projects/ - so the
# detector was blind to the firstmate pool: the pool every firstmate crewmate runs
# in, and the pool whose crash-dirty slot motivated this script in the first place.
C=$(new_case i)
printf '1     available    /pool/1/proj\n' > "$C/status.txt"   # projects/proj: healthy
# A separate repo, OUTSIDE projects/, reachable only through a task meta.
fm_git_init_commit "$C/outside"
outside_slot="$C/th-root/outside/1/repo"
mkdir -p "$(dirname "$outside_slot")"
git -C "$C/outside" worktree add -q --detach "$outside_slot" 2>/dev/null
printf 'a dead crew work in the firstmate pool\n' > "$outside_slot/rescue-me.txt"
fm_write_meta "$C/home/state/t1.meta" \
  "window=firstmate:fm-t1" "worktree=$outside_slot" "project=$C/outside" "kind=ship"
# treehouse answers per-cwd: the outside repo's pool has the dirty slot.
cat > "$C/fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  status)
    if [ "\$PWD" = "$(cd "$C/outside" && pwd -P)" ]; then
      printf '1     dirty        %s\n' "$outside_slot"
    else
      cat "\${TH_STATUS:?}"
    fi
    ;;
esac
exit 0
SH
chmod +x "$C/fakebin/treehouse"
out=$(run_status "$C")
assert_contains "$out" "is DIRTY" "(i) a pool named only by a task meta (the firstmate pool) must be swept"
assert_present "$outside_slot/rescue-me.txt" "(i) and its work must survive the report"
pass "(i) the firstmate pool - named by a meta, not under projects/ - is swept too"

# --- (j) the sweep must be READ-ONLY: no pool may be created by looking ---------
# `treehouse status` is not a read: merely asking it about a repo CREATES that
# repo's pool directory (verified against treehouse v2.0.0). A session-start sweep
# over every project therefore used to leave an empty pool behind for each one -
# and the test suite alone littered ~100 of them into the operator's real
# ~/.treehouse. A project with no slots has nothing to diagnose; do not touch it.
C=$(new_case j)
printf '1     available    /pool/1/proj\n' > "$C/status.txt"
# A real treehouse that records every invocation, so we can prove it is not called.
cat > "$C/fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
printf 'called %s\n' "\$*" >> "$C/th-calls.log"
case "\${1:-}" in status) cat "\${TH_STATUS:?}" ;; esac
exit 0
SH
chmod +x "$C/fakebin/treehouse"
: > "$C/th-calls.log"
run_status "$C" >/dev/null
[ ! -s "$C/th-calls.log" ] \
  || fail "(j) a project with no pool slots must not be handed to treehouse at all (it would create a pool): $(cat "$C/th-calls.log")"
pass "(j) a project with no slots is never handed to treehouse - the sweep creates no pools"
