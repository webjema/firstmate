#!/usr/bin/env bash
# fm-pool-warm.sh - keep ONE free, warm treehouse slot ready for every project
# with work in flight, so a crew never waits on a dependency install.
# THIS HEADER IS THE SINGLE OWNER OF THE WARM POLICY.
#
# Usage: fm-pool-warm.sh            sweep every project with a task in flight
#        fm-pool-warm.sh <project>  one project (a name under projects/, or a path)
#        fm-pool-warm.sh --status   print each pool's headroom and exit (no warming)
#
# WHY. A crew handed an EMPTY slot installs the project's dependencies itself
# before it can build or test anything - minutes of the user's time, on the spawn
# path. So pay it EARLY, in the background, on firstmate's time.
#
# THE INVARIANT: always-plus-one. For each project with work in flight, at least
# one slot must sit AVAILABLE and warm. When the last free slot is taken, the
# next one is provisioned preventively. This self-tunes with no target size: a
# user who habitually runs 4 tasks settles at 5 slots and stops growing,
# because the 5th is never consumed.
#
# WARMING IS TWO STEPS, and the second one is not optional:
#
#   treehouse get --lease --lease-holder fm-warm-<project>   # create-or-reset
#   bin/fm-worktree-provision.sh <path>                      # populate the deps
#   treehouse return --force <path>                          # release the lease
#
# TREEHOUSE INSTALLS NOTHING. It hands over an empty worktree, and it CANNOT be
# made to install from a repo's own treehouse.toml: treehouse ignores hooks there
# by design, and its only working hook home is the user's global config, which
# firstmate does not write. docs/treehouse-backend.md records that finding and its
# evidence - read it before proposing a repo-level hook again. This header used to
# claim a post_create hook did the install, and cited 137s cold versus 2s warm
# from bin/fm-provision-lib.sh on that basis. No such hook has ever existed on
# this box, so a "warmed" slot was merely a CREATED one and the first crew still
# paid the whole install.
#
# fm-worktree-provision.sh closes that gap by APFS-cloning each dependency tree
# from a per-pool cache and reconciling it with the project's own installer; its
# header owns that contract. Measured on optiroq (2026-07-27, treehouse v2.1.0,
# `df` deltas - `du` cannot see a clone saving because it counts shared blocks):
#
#   cold install, 3 roots  ..... 56 s, 2.70 GB of real disk
#   clone + reconcile      ..... 53 s,   96 MB of real disk
#
# So this buys DISK, not time: 96.5% less per additional slot, with the install
# time essentially unchanged because npm install dominates and the npm cache is
# already shared. The time win is the one warming already gave - it is paid here
# instead of on the spawn path.
#
# THE COLD-SPAWN GAP IS ACCEPTED. A `treehouse get` that finds no warm slot still
# hands over an empty one and the crew installs for itself. That is exactly the
# behavior that predates this script, not a regression, and always-plus-one closes
# it in steady state. Provisioning on the spawn path would need the global hook
# this design deliberately declines.
#
# WHY THE DEPS SURVIVE THE RETURN: treehouse's reset is `git clean -fd` with NO
# -x, so gitignored trees are never removed. Verified end to end on 2026-07-14
# (treehouse v2.0.0, optiroq): after the return, node_modules/, src/portal-ui/
# node_modules/ and src/admin-app/node_modules/ all survived - 2.7 GB intact.
# That is the whole reason a returned slot stays warm.
#
# AND WHY IT MUST COME BACK CLEAN. That same `git clean -fd` has no checkout in
# it, so it cannot revert a TRACKED file - and npm rewrites the lockfile it
# installed from. A warm that leaves that edit behind returns a `dirty` slot, which
# treehouse skips on every later `get` and refuses to prune: each warm would retire
# one slot permanently, and bin/fm-pool-status.sh would report the wreckage as a
# dead crew's unlanded work. fm-worktree-provision.sh restores exactly what its
# installer dirtied, on the kill path too; its header owns that contract.
#
# THE LEASE IS WHAT MAKES IT SAFE. It is held for the WHOLE install, so a
# concurrent `treehouse get` can never be handed a half-installed slot, and it is
# released the moment the warm is done - warm or cold.
#
# AND THE RELEASE IS VERIFIED, NEVER ASSUMED. `treehouse return` on a dirty slot
# aborts and still exits 0, so for a month every warm logged WARMED while its lease
# survived: availability stayed 0, this script's own invariant provisioned another
# slot every cycle, and the pool grew to 17 GB before the disk budget stopped it.
# fm_pool_release now forces the return AND asks treehouse whether the lease is
# actually gone; the "still LEASED" branch below is what that honesty surfaces.
#
# THE REAPER: A LEAKED WARM LEASE IS RECLAIMED, NOT ROUTED AROUND. Before growing
# the pool, a warmer asks whether this pool already holds a lease under its OWN warm
# holder; if it does, it releases that lease and then warms through the normal path,
# where `treehouse get` hands back the slot it just freed. It is the only
# self-healing in this path, and its safety rests on the pool lock, not on a string
# test alone:
#
#   1. Only the pool-lock holder ever takes an fm-warm-* lease - warm_one leases
#      strictly after acquire_pool_lock and releases strictly before the lock.
#   2. So once THIS warmer holds that lock, no other warmer for this pool is
#      running, and any fm-warm-<name> lease it can see is an orphan of a warm that
#      is already over. (Which is why liveness is NOT re-tested here: we are the
#      live warmer, so fm_pool_warmer_live is true by construction and would refuse
#      every reap.)
#   3. The holder is matched exactly, inside THIS pool's own status. A crew or
#      secondmate lease is held under a task id (bin/fm-home-seed.sh), never under
#      fm-warm-*, so no reachable lease belongs to anyone but this warm path.
#
# A live warmer's lease is untouchable for a plainer reason still: a second warmer
# never gets past acquire_pool_lock at all.
#
# RELEASE, THEN LEASE AGAIN - never provision under the dead warm's lease. The warm
# then holds a lease it took itself, and a release that keeps failing (a slot git can
# no longer return) falls through to adding a slot rather than retrying the same
# unreclaimable one every cycle, which would leave the project with no warm slot at
# all. Reclaim runs BEFORE both ceilings and skips them on success, because it hands
# `treehouse get` a free slot instead of asking for a new one - and a pool at its
# budget is exactly where a stranded slot must still be recovered.
#
# It is not free. The reclaimed slot may have been created and never populated, so
# the provision that follows can still install a full dependency tree - the same disk
# the pool would have spent on the new slot it is NOT creating.
#
# It only fires when the pool has no free slot, because that is the only case that
# gets this far (see the avail >= 1 early return). A leaked lease beside a free slot
# waits for the cycle that needs it; bin/fm-pool-status.sh reports it meanwhile.
#
# One accepted risk, in two shapes: the pool lock dies with the warmer PROCESS, not
# with its children, so a warm SIGKILLed (or timed out - `timeout` sends TERM and
# returns) can leave a live `treehouse get` or installer running against a slot whose
# lease the next cycle then judges an orphan and forces back. The loser is a slot
# left dirty or half-reset, which fm-pool-status.sh reports and a human can reclaim -
# strictly better than the behavior this replaces, where that slot left the pool
# forever. No crew work is ever at stake: the racing process is our own warm.
#
# ONE TIME BUDGET FOR THE WHOLE WARM, taken BEFORE the lease is asked for and
# handed to the provisioner as FM_PROVISION_DEADLINE. The `treehouse get` is
# bounded by the same number, so a deadline computed after it returned would let a
# slow get plus a full install hold the POOL LOCK - shared with every secondmate
# home pointing at this pool - for twice the bound, blocking the other warmer for
# that whole doubled window.
#
# A COLD SLOT IS LOGGED AS COLD. The provisioner's exit status is propagated: only
# a provision that exited 0 is logged `WARMED` and clears the blocked sentinel.
# Before the provision step existed, an install failure surfaced through the
# `treehouse get` rc as `FAILED <name>`; swallowing it here instead would leave a
# permanently failing install invisible in the only log that records it.
#
# SINGLE WARMER PER POOL. Secondmate homes share pools, and two warmers racing
# would over-provision by GBs. The lock is scoped to the POOL (keyed by the
# project's physical path, which is exactly what treehouse keys a pool by), NOT to
# the firstmate home - see warm_lock_dir. A second warmer exits silently.
#
# NEVER BLOCKS, NEVER BREAKS A SPAWN. The watcher launches this detached on its
# slow FM_CHECK_INTERVAL cadence, never on the hot path. Every failure - network,
# broken lockfile, treehouse error - is logged to state/.pool-warm.log and
# retired quietly; this script always exits 0 for a failed warm, and a failed warm
# never corrupts a slot (the lease is released either way) nor wakes the user.
#
# TWO CEILINGS, both of which STOP warming rather than fill the disk silently:
#
#   DISK BUDGET (per project pool). Default 20 GB, FM_POOL_DISK_BUDGET_GB or
#     config/pool-disk-budget-gb. A fixed slot COUNT would be wrong here: optiroq
#     is ~2.8 GB/slot (~7 slots inside 20 GB) while firstmate is ~6 MB/slot
#     (effectively uncapped). The next slot's size is estimated as the mean of the
#     existing ones; a pool with no slots yet is always allowed its first.
#   MAX_TREES. treehouse's own pool ceiling (treehouse.toml, default 16).
#
# When a ceiling blocks a warm, it is reported ONCE with the real numbers (a
# repeat is suppressed until the situation changes) and surfaced at session start
# through bin/fm-pool-status.sh, not as a mid-flight wake: a full pool is a
# capacity fact for the user to decide on, never an emergency to interrupt them
# with.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TREEHOUSE_ROOT="${FM_TREEHOUSE_ROOT:-$HOME/.treehouse}"
LOG="$STATE/.pool-warm.log"

# shellcheck source=bin/fm-pool-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pool-lib.sh"

log() {  # <message>
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$LOG" 2>/dev/null || true
}

# Report a blocked warm ONCE. The sentinel carries the reason, so a CHANGED
# reason (a raised budget, a reclaimed slot) reports again while an unchanged one
# stays quiet cycle after cycle.
report_once() {  # <project> <reason>
  local project=$1 reason=$2 sentinel prev
  sentinel="$STATE/.pool-warm-blocked.$(fm_pool_key "$project")"
  prev=$(cat "$sentinel" 2>/dev/null || true)
  if [ "$prev" != "$reason" ]; then
    printf '%s\n' "$reason" > "$sentinel" 2>/dev/null || true
    log "BLOCKED $project: $reason"
  fi
}

clear_blocked() {  # <project>
  rm -f "$STATE/.pool-warm-blocked.$(fm_pool_key "$1")" 2>/dev/null || true
}

# warm_lock_dir <project-real-path>: the POOL-scoped lock. Keyed by the project's
# physical path (what treehouse itself keys a pool by) and held under the shared
# treehouse root, so every firstmate home - primary and secondmates alike - that
# points at the same clone contends for the SAME lock. A home-scoped lock would
# let two homes warm the same pool at once and over-provision it by GBs.
warm_lock_dir() {  # <project-real-path>
  printf '%s/.fm-warm-locks/%s' "$TREEHOUSE_ROOT" "$(fm_pool_key "$1")"
}

# Returns 0 (and holds the lock) only for the single warmer that wins the pool.
# fm-pool-lib.sh owns the locking contract (flock, with a pid+boot directory
# fallback) and the reasoning behind it; do not re-roll a lock here.
acquire_pool_lock() {  # <project-real-path>
  fm_pool_lock_acquire "$(warm_lock_dir "$1")"
}

# Release BOTH resources this warmer may hold, in the order that cannot leak:
# the treehouse LEASE first, then the lock.
#
# The lease is the one that causes permanent damage. treehouse: "A leased worktree
# is never handed out by a later get and never removed by prune ... until you
# release it." So a warmer that dies mid-install with a lease held removes that
# slot from the pool FOREVER - its gigabytes still counted against the disk budget,
# recovered only if a human reads a POOL_SLOT line. bash runs an EXIT trap on
# SIGTERM, so a graceful reboot is a cleanup opportunity, and this takes it.
# WARM_LEASE_PROJECT is a global precisely so the trap can see it; a `local` inside
# warm_one is invisible here, which is how the lease leaked.
#
# IT ASKS TREEHOUSE WHICH SLOT IT HOLDS; IT NEVER FORCES A REMEMBERED PATH. Two
# reasons, and the second is a safety rail. A warmer killed mid-install holds a lease
# whose path it never learned - `treehouse get --lease` marks the lease first and
# prints the path only at the end - so a remembered path is not even available in the
# case this trap exists for. And a path we remember may already be RELEASED, which
# makes it a slot `treehouse get` can hand to a crew; forcing that would hard-reset
# someone's work. treehouse's own status is the only thing that knows, so ask it.
# Whatever it names under our holder is ours to release: only a pool-lock holder ever
# takes an fm-warm-* lease, and this runs before the lock goes back.
release_warm_resources() {
  local slot holder err
  if [ -n "${WARM_LEASE_PROJECT:-}" ]; then
    holder="fm-warm-$(basename "$WARM_LEASE_PROJECT")"
    slot=$(fm_pool_leased_by "$WARM_LEASE_PROJECT" "$holder" 2>/dev/null || true)
    if [ -n "$slot" ]; then
      err=$(fm_pool_release "$WARM_LEASE_PROJECT" "$slot" 2>&1) || \
        log "LEAKED $(basename "$WARM_LEASE_PROJECT"): could not release lease on $slot${err:+ - $err}"
    fi
    WARM_LEASE_PROJECT=""
  fi
  fm_pool_lock_release
}

release_pool_lock() { release_warm_resources; }

# warm_one <project-real-path>: enforce always-plus-one for ONE pool.
warm_one() {  # <project-real-path>
  local project=$1 name avail slots max_trees pool_dir used_kb est_kb budget_kb path rc timeout_secs line
  local warm_deadline prov_rc prov_out reaped reclaimed rel_rc rel_err
  name=$(basename "$project")

  fm_pool_read "$project" || {
    log "SKIP $name: treehouse status failed (not a pool, or treehouse errored)"
    return 0
  }
  avail=$FM_POOL_AVAILABLE
  slots=$FM_POOL_SLOTS

  # The invariant already holds: a free warm slot is waiting. Nothing to do -
  # and this is the common case, so it must stay cheap.
  if [ "$avail" -ge 1 ]; then
    clear_blocked "$project"
    return 0
  fi

  acquire_pool_lock "$project" || return 0   # another warmer owns this pool

  # Re-read under the lock: the pool may have changed while we waited.
  fm_pool_read "$project" || { release_pool_lock; return 0; }
  if [ "$FM_POOL_AVAILABLE" -ge 1 ]; then
    clear_blocked "$project"
    release_pool_lock
    return 0
  fi
  slots=$FM_POOL_SLOTS

  # ONE deadline for the WHOLE warm, taken before any lease is asked for or reused.
  # Taking it after `treehouse get` returned would restart the clock: the get is
  # itself bounded by timeout_secs, so a slow one plus a full provision budget held
  # the pool lock - which is shared with every secondmate home pointing at this pool
  # - for up to twice the bound the header promises.
  timeout_secs=$(fm_pool_warm_timeout)
  warm_deadline=$(( $(date +%s) + timeout_secs ))

  # THE REAPER. We hold this pool's lock, and only a lock holder ever takes an
  # fm-warm-* lease, so a lease still standing under OUR holder belongs to a warm
  # that is already over - reclaim that slot rather than grow the pool around it.
  # The header owns the full scope argument, including why liveness is deliberately
  # not re-tested here and why no crew lease is reachable.
  #
  # It RELEASES the orphan and then leases again through the normal path, rather
  # than provisioning under the dead warm's lease. Two reasons: the warm then holds
  # a lease it took itself, and a release that keeps FAILING - a slot git can no
  # longer return - falls through to adding a slot instead of retrying the same
  # unreclaimable one forever, which would leave the project with no warm slot at
  # all. The freed slot is what `treehouse get` hands back, so the pool does not
  # grow; the ceilings are skipped for exactly that reason.
  reclaimed=no
  reaped=$(fm_pool_leased_by "$project" "fm-warm-$name")
  if [ -n "$reaped" ]; then
    rel_rc=0
    rel_err=$(fm_pool_release "$project" "$reaped" 2>&1) || rel_rc=$?
    if [ "$rel_rc" -eq 0 ]; then
      log "REAP $name: $reaped was still leased by this pool's own warm holder with no warmer running; reclaimed it instead of adding a slot"
      # The ceiling skip is EARNED, never assumed: ask whether the pool really has a
      # free slot now. A released slot can fail to become one - treehouse can leave it
      # dirty, and a crew takes slots with a plain `treehouse get` while holding no
      # pool lock, so it can consume this one in the gap. Either way the `get` below
      # would CREATE a slot, and skipping the budget for a creation is the exact
      # outcome this branch exists to end.
      if fm_pool_read "$project" && [ "$FM_POOL_AVAILABLE" -ge 1 ]; then
        reclaimed=yes
      else
        log "WARM $name: the reclaimed slot is not free to take; falling back to provisioning one"
      fi
      slots=$FM_POOL_SLOTS
    else
      log "FAILED $name: could not reclaim the leaked lease on $reaped; adding a slot instead${rel_err:+ - $rel_err}"
    fi
  fi

  if [ "$reclaimed" = no ]; then
    # Ceiling 1: treehouse's own max_trees.
    max_trees=$(fm_pool_max_trees "$project")
    if [ "$slots" -ge "$max_trees" ]; then
      report_once "$project" "pool is at treehouse's max_trees ($slots/$max_trees slots); no warm slot can be added until one is reclaimed"
      release_pool_lock
      return 0
    fi

    # Ceiling 2: the disk budget. Estimate the next slot from the mean of the
    # existing ones, because slot size is a property of the PROJECT (optiroq
    # ~2.8 GB, firstmate ~6 MB) and a fixed count would treat those identically.
    pool_dir=$FM_POOL_DIR
    budget_kb=$(fm_pool_disk_budget_kb "$CONFIG")
    used_kb=0
    est_kb=0
    if [ -n "$pool_dir" ] && [ -d "$pool_dir" ]; then
      used_kb=$(du -sk "$pool_dir" 2>/dev/null | awk '{print $1}')
      [ -n "$used_kb" ] || used_kb=0
      [ "$slots" -gt 0 ] && est_kb=$((used_kb / slots))
    fi
    if [ "$est_kb" -gt 0 ] && [ $((used_kb + est_kb)) -gt "$budget_kb" ]; then
      report_once "$project" "disk budget reached: pool uses $(fm_pool_gb "$used_kb") GB and the next slot needs about $(fm_pool_gb "$est_kb") GB, over the $(fm_pool_gb "$budget_kb") GB budget ($slots slots). Raise FM_POOL_DISK_BUDGET_GB or reclaim a slot; no warm slot will be added until then"
      release_pool_lock
      return 0
    fi

    # Warm it. The lease is held across the whole install, so no crew can be handed
    # this slot half-installed.
    #
    # BOUNDED, because an unbounded warm is the worst failure in this system: a hung
    # install (a dead registry, a lockfile that never resolves) would hang the warmer
    # forever while it holds
    # BOTH the pool lock - with a live pid, so no other warmer may ever reclaim it -
    # and the treehouse lease, whose slot then leaves the pool permanently. And a
    # live-pid lock makes fm-pool-status.sh's warmer_is_live() true, so the leaked
    # lease is not even reported. Permanent AND invisible. The timeout ends that: the
    # warm dies, the EXIT trap releases the lease and the lock, and the next cycle
    # simply tries again.
    log "WARM $name: no free slot ($slots in use); provisioning one preventively"
  fi

  # Record the intent to lease BEFORE leasing: if we are killed between treehouse
  # taking the lease and printing the path, the trap must still know which pool to
  # release. fm_pool_release on a pool with no lease held is a harmless no-op.
  WARM_LEASE_PROJECT=$project
  rc=0
  path=$(fm_pool_lease "$project" "fm-warm-$name" "$timeout_secs") || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$path" ]; then
    if [ "$rc" -eq 124 ]; then
      log "FAILED $name: warm timed out after ${timeout_secs}s (hung install?); releasing the lease and retrying next cycle"
    else
      log "FAILED $name: treehouse get --lease failed; retiring, will retry next cycle"
    fi
    # A timed-out `treehouse get` may still have left a lease behind. Ask treehouse
    # to release the pool's slot rather than assume nothing was taken.
    release_warm_resources
    return 0
  fi

  # THIS is what makes a warm slot warm. treehouse hands over an EMPTY worktree -
  # it installs nothing, and cannot be made to from a repo's own treehouse.toml
  # (see the header) - so without this step "warmed" would mean nothing more than
  # "created", and the first crew would still pay the whole install.
  #
  # It shares this warm's single deadline (warm_deadline above), so three install
  # roots cannot hold the lease and the pool lock for three times the bound.
  #
  # ITS STATUS IS NOT DISCARDED. A failed provision leaves a merely-COLD slot -
  # survivable, and exactly what the pool held before this existed - but it is not
  # a warm one, and calling it warm is worse than the cold slot itself: this log is
  # the only place a permanently failing install is visible, and `clear_blocked`
  # would tell the disk-budget rail the warm succeeded. Before this step existed the
  # failure surfaced through the `treehouse get` rc as `FAILED <name>`; it surfaces
  # here now. Capturing rather than reading from a process substitution is what makes
  # that possible at all - `< <(...)` throws the child's status away.
  prov_rc=0
  prov_out=$(FM_PROVISION_DEADLINE=$warm_deadline \
               "$SCRIPT_DIR/fm-worktree-provision.sh" "$path" 2>&1) || prov_rc=$?
  while IFS= read -r line; do
    [ -n "$line" ] && log "PROVISION $name: $line"
  done <<EOF
$prov_out
EOF

  # Release the lease: the slot is now AVAILABLE, and warm if the provision said so.
  # Its deps survive the return (git clean -fd, no -x) - that is what makes it warm
  # for the next crew. The lease is released either way: a cold slot still belongs
  # back in the pool, and holding it would cost more than the failed install did.
  #
  # fm_pool_release VERIFIES the release against treehouse's own status rather than
  # trusting its exit code, which is what makes the failure branch below reachable at
  # all: a `treehouse return` that aborts on a dirty slot exits 0.
  rel_rc=0
  rel_err=$(fm_pool_release "$project" "$path" 2>&1) || rel_rc=$?
  if [ "$rel_rc" -eq 0 ]; then
    WARM_LEASE_PROJECT=""
    if [ "$prov_rc" -eq 0 ]; then
      log "WARMED $name: $path is free and warm"
      clear_blocked "$project"
    else
      log "FAILED $name: $path is free but COLD (provision exited $prov_rc); the next crew installs for itself"
    fi
  else
    # The lease is still held, whatever the install did. Do NOT hide that: a
    # still-leased slot is one the pool cannot hand out. WARM_LEASE_PROJECT stays
    # set, so release_warm_resources below asks treehouse which slot this holder
    # owns and tries once more - not necessarily THIS slot, because with several
    # leaks outstanding it releases whichever the pool reports first. Every one of
    # them is a warm orphan, so any of them is a safe thing to free.
    log "FAILED $name: treehouse return failed for $path; the slot is still LEASED${rel_err:+ - $rel_err}"
  fi
  release_warm_resources
  return 0
}

# The projects to keep warm: those with work in flight. A project with no crew
# working on it needs no spare, so an idle fleet warms nothing.
projects_in_flight() {
  local meta project kind seen=""
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(sed -n 's/^kind=//p' "$meta" | head -n 1)
    [ "$kind" = secondmate ] && continue   # a secondmate home is not a pooled project
    project=$(sed -n 's/^project=//p' "$meta" | head -n 1)
    [ -n "$project" ] && [ -d "$project" ] || continue
    project=$(cd "$project" 2>/dev/null && pwd -P) || continue
    case " $seen " in *" $project "*) continue ;; esac
    seen="$seen $project"
    printf '%s\n' "$project"
  done
}

resolve_project() {  # <name-or-path>
  local arg=$1
  if [ -d "$arg" ]; then
    (cd "$arg" && pwd -P)
  elif [ -d "$PROJECTS/$arg" ]; then
    (cd "$PROJECTS/$arg" && pwd -P)
  else
    return 1
  fi
}

# A global, NOT a local: the EXIT trap must be able to see which POOL this warm is
# leasing from. It deliberately remembers no slot path - release_warm_resources asks
# treehouse which slot the holder owns at trap time - but without the project a
# warmer killed mid-install cannot ask at all, which is how it leaked its lease and
# removed a slot from the pool forever.
WARM_LEASE_PROJECT=""
# INT/TERM as well as EXIT: bash runs the EXIT trap on a caught signal, and a
# reboot's SIGTERM is precisely the case that was leaking the lease.
trap release_warm_resources EXIT INT TERM

case "${1:-}" in
  --status)
    # `while read`, not `for $(...)`: a project path may contain spaces.
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if fm_pool_read "$p"; then
        printf '%s: %s slots, %s available (max_trees %s)\n' \
          "$(basename "$p")" "$FM_POOL_SLOTS" "$FM_POOL_AVAILABLE" "$(fm_pool_max_trees "$p")"
      else
        printf '%s: no readable pool\n' "$(basename "$p")"
      fi
    done < <(projects_in_flight)
    ;;
  "")
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      warm_one "$p"
    done < <(projects_in_flight)
    ;;
  *)
    proj=$(resolve_project "$1") || { echo "error: no such project: $1" >&2; exit 1; }
    warm_one "$proj"
    ;;
esac
exit 0
