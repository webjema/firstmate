#!/usr/bin/env bash
# fm-pool-warm.sh - keep ONE free, warm treehouse slot ready for every project
# with work in flight, so a crew never waits on a dependency install.
# THIS HEADER IS THE SINGLE OWNER OF THE WARM POLICY.
#
# Usage: fm-pool-warm.sh            sweep every project with a task in flight
#        fm-pool-warm.sh <project>  one project (a name under projects/, or a path)
#        fm-pool-warm.sh --status   print each pool's headroom and exit (no warming)
#
# WHY. A cold slot's post_create hook installs the project's dependencies before
# treehouse hands it over: a measured 137s for optiroq on this box, versus 2s for
# a warm slot (bin/fm-provision-lib.sh records the measurement). Paying that on
# the spawn path means a crew - and the captain - waits. So pay it EARLY, in the
# background, on firstmate's time.
#
# THE INVARIANT: always-plus-one. For each project with work in flight, at least
# one slot must sit AVAILABLE and warm. When the last free slot is taken, the
# next one is provisioned preventively. This self-tunes with no target size: a
# captain who habitually runs 4 tasks settles at 5 slots and stops growing,
# because the 5th is never consumed.
#
# WARMING IS THIN - IT IS TREEHOUSE, NOT A REIMPLEMENTATION. To warm a slot:
#
#   treehouse get --lease --lease-holder fm-warm-<project>   # create-or-reset,
#                                                            # runs post_create
#                                                            # (i.e. installs deps)
#   treehouse return <path>                                  # release the lease
#
# and the slot is then both AVAILABLE and warm. Verified end to end on 2026-07-14
# (treehouse v2.0.0, optiroq): after the return, node_modules/, src/portal-ui/
# node_modules/ and src/admin-app/node_modules/ all survived - 2.7 GB intact.
# They survive because treehouse's reset is `git clean -fd` with NO -x, so
# gitignored build output is never removed. That is the whole reason a returned
# slot stays warm, and the reason this script can be so thin.
#
# THE LEASE IS WHAT MAKES IT SAFE. It is held for the WHOLE install, so a
# concurrent `treehouse get` can never be handed a half-installed slot, and it is
# released the moment the slot is warm.
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
# never corrupts a slot (the lease is released either way) nor wakes the captain.
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
# capacity fact for the captain to decide on, never an emergency to interrupt them
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
# A lock whose owner pid is gone is reclaimed: a warmer killed mid-install (a
# reboot) must not wedge the pool's warming forever.
acquire_pool_lock() {  # <project-real-path>
  local lock owner
  lock=$(warm_lock_dir "$1")
  mkdir -p "$(dirname "$lock")" 2>/dev/null || return 1
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || true
    WARM_LOCK=$lock
    return 0
  fi
  owner=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    return 1   # a live warmer owns this pool
  fi
  # Stale: the owner is gone. Reclaim and retry once.
  rm -rf "$lock" 2>/dev/null || true
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || true
    WARM_LOCK=$lock
    return 0
  fi
  return 1
}

release_pool_lock() {
  [ -n "${WARM_LOCK:-}" ] && rm -rf "$WARM_LOCK" 2>/dev/null
  WARM_LOCK=""
}

# warm_one <project-real-path>: enforce always-plus-one for ONE pool.
warm_one() {  # <project-real-path>
  local project=$1 name avail slots max_trees pool_dir used_kb est_kb budget_kb path rc
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
  log "WARM $name: no free slot ($slots in use); provisioning one preventively"
  rc=0
  path=$(fm_pool_lease "$project" "fm-warm-$name") || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$path" ]; then
    log "FAILED $name: treehouse get --lease failed; retiring, will retry next cycle"
    release_pool_lock
    return 0
  fi

  # Release the lease: the slot is now AVAILABLE *and* warm. Its deps survive the
  # return (git clean -fd, no -x) - that is what makes it warm for the next crew.
  if fm_pool_release "$project" "$path"; then
    log "WARMED $name: $path is free and warm"
    clear_blocked "$project"
  else
    # The install succeeded but the lease is still held. Do NOT hide that: a
    # still-leased slot is one the pool cannot hand out.
    log "FAILED $name: warmed $path but treehouse return failed; the slot is still LEASED"
  fi
  release_pool_lock
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

WARM_LOCK=""
trap release_pool_lock EXIT

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
