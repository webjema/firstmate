#!/usr/bin/env bash
# fm-pool-lib.sh - the single owner of "what does firstmate know about a treehouse
# pool". Sourced by bin/fm-pool-warm.sh and bin/fm-pool-status.sh.
#
# treehouse (the external Go binary) owns the pool; firstmate only READS it, and
# reads it exactly one way: `treehouse status` run inside the project clone. That
# output is the structured contract, verified against treehouse v2.0.0 on
# 2026-07-14:
#
#   1     available    ~/.treehouse/optiroq-80b6c6/1/optiroq
#   2     leased       ~/.treehouse/optiroq-80b6c6/2/optiroq  (held by fm-warm-optiroq)
#   3     in-use       ~/.treehouse/optiroq-80b6c6/3/optiroq
#                      bash (1620624), claude (1620863), npm exec (1620891)
#   4     dirty        ~/.treehouse/optiroq-80b6c6/4/optiroq
#
# A slot line starts with the slot NAME; the indented continuation lines under an
# in-use slot list its processes and are not slots. Paths are ~-abbreviated.
#
# DIRTY IS THE ONE THAT BITES (verified, 2026-07-14): `treehouse get` SKIPS a
# dirty slot forever, and `treehouse prune` REFUSES to reclaim it ("Skipped 1
# unsafe idle worktree: uncommitted changes"). A crew that dies mid-task - three
# box reboots did exactly this - leaves its slot dirty, and the pool silently
# shrinks with nothing noticing. bin/fm-pool-status.sh exists to notice.
set -u

# fm_pool_key <project-real-path>: a stable, filesystem-safe slug for one POOL.
# Keyed by the project's physical path because that is what treehouse itself keys
# a pool by - so every firstmate home pointing at the same clone derives the same
# key, which is what makes the warm lock pool-scoped rather than home-scoped.
fm_pool_key() {  # <project-real-path>
  local path=$1 hash
  hash=$(printf '%s' "$path" | cksum | awk '{print $1}')
  printf '%s-%s' "$(basename "$path")" "$hash"
}

# fm_pool_read <project-real-path>: read the pool once. Returns 1 when treehouse
# cannot report on it at all (not a pool, treehouse missing/errored). On success
# sets:
#   FM_POOL_TABLE      one line per slot: "<name>\t<state>\t<path>\t<detail>"
#   FM_POOL_SLOTS      total slot count
#   FM_POOL_AVAILABLE  slots that are free AND warm - i.e. what a `treehouse get`
#                      could actually hand over right now
#   FM_POOL_DIR        the pool directory (parent of the slots), or empty
fm_pool_has_slots() {  # <project-real-path>
  # Does this project have any treehouse slots at all? Answered from GIT, not from
  # treehouse - because `treehouse status` is NOT read-only: merely asking it about
  # a repo CREATES that repo's pool directory (verified 2026-07-14). A diagnostic
  # that sweeps every project must not leave a trail of empty pools behind it, and
  # a test suite must not litter the operator's real ~/.treehouse.
  # A pool slot is a linked git worktree of the project, so git already knows. A
  # project with no linked worktree has no slots, hence nothing to diagnose - and
  # that includes no dirty slot, so this guard cannot hide the incident.
  [ "$(git -C "$project" worktree list --porcelain 2>/dev/null | grep -c '^worktree ')" -gt 1 ]
}

fm_pool_read() {  # <project-real-path>
  local project=$1 out line name state path detail
  out=$( (cd "$project" 2>/dev/null && treehouse status 2>/dev/null) ) || return 1
  FM_POOL_TABLE=""
  FM_POOL_SLOTS=0
  FM_POOL_AVAILABLE=0
  FM_POOL_DIR=""
  while IFS= read -r line; do
    # Slot lines start with the slot name in column 1; process/continuation lines
    # under an in-use slot are indented, and must never be counted as slots.
    case "$line" in
      ''|[[:space:]]*) continue ;;
    esac
    name=$(printf '%s' "$line" | awk '{print $1}')
    state=$(printf '%s' "$line" | awk '{print $2}')
    path=$(printf '%s' "$line" | awk '{print $3}')
    [ -n "$name" ] && [ -n "$state" ] && [ -n "$path" ] || continue
    case "$path" in
      '~'/*) path="$HOME/${path#'~'/}" ;;
      /*) ;;
      *) continue ;;   # not a slot line
    esac
    detail=$(printf '%s' "$line" | sed -n 's/.*(held by \([^)]*\)).*/\1/p')
    FM_POOL_SLOTS=$((FM_POOL_SLOTS + 1))
    [ "$state" = available ] && FM_POOL_AVAILABLE=$((FM_POOL_AVAILABLE + 1))
    [ -n "$FM_POOL_DIR" ] || FM_POOL_DIR=$(dirname "$(dirname "$path")")
    FM_POOL_TABLE="${FM_POOL_TABLE}${name}	${state}	${path}	${detail}
"
  done <<EOF
$out
EOF
  return 0
}

# fm_pool_max_trees <project-real-path>: treehouse's own pool ceiling. Its
# treehouse.toml owns the value; 16 is treehouse's documented default.
fm_pool_max_trees() {  # <project-real-path>
  local project=$1 value
  value=$(sed -n 's/^[[:space:]]*max_trees[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "$project/treehouse.toml" 2>/dev/null | head -n 1)
  case "${value:-}" in
    ''|*[!0-9]*) printf '16' ;;
    *) printf '%s' "$value" ;;
  esac
}

# fm_pool_disk_budget_gb <config-dir>: the per-project-pool disk ceiling, in GB.
# Precedence: FM_POOL_DISK_BUDGET_GB, then config/pool-disk-budget-gb, then 20.
# docs/configuration.md owns the knob.
fm_pool_disk_budget_gb() {  # <config-dir>
  local config=$1 value="${FM_POOL_DISK_BUDGET_GB:-}"
  if [ -z "$value" ] && [ -f "$config/pool-disk-budget-gb" ]; then
    value=$(tr -d '[:space:]' < "$config/pool-disk-budget-gb" 2>/dev/null || true)
  fi
  case "${value:-}" in
    ''|*[!0-9]*) printf '20' ;;
    *) printf '%s' "$value" ;;
  esac
}

# fm_pool_disk_budget_kb <config-dir>: the same ceiling in KB, which is the unit
# the check actually works in. FM_POOL_DISK_BUDGET_KB is an INTERNAL override so
# the behavior test can exercise the budget with a few small files instead of
# staging 20 GB; operators set the GB knob above.
fm_pool_disk_budget_kb() {  # <config-dir>
  local kb="${FM_POOL_DISK_BUDGET_KB:-}"
  case "$kb" in
    ''|*[!0-9]*) printf '%s' "$(( $(fm_pool_disk_budget_gb "$1") * 1024 * 1024 ))" ;;
    *) printf '%s' "$kb" ;;
  esac
}

# fm_pool_gb <kb>: kilobytes as GB with one decimal, for operator-facing numbers.
fm_pool_gb() {  # <kb>
  awk -v kb="${1:-0}" 'BEGIN { printf "%.1f", kb / 1048576 }'
}

# fm_pool_lease <project-real-path> <holder> [timeout-secs]: reserve a slot,
# creating-or-resetting it and running the post_create hook (i.e. installing deps).
# Prints its path. This IS the warm operation - treehouse does the work, firstmate
# does not reimplement any of it.
# BOUNDED when a timeout is given (exit 124 on expiry, per `timeout`): an install
# that hangs must not hold a lease and a pool lock forever. See bin/fm-pool-warm.sh.
fm_pool_lease() {  # <project-real-path> <holder> [timeout-secs]
  local project=$1 holder=$2 secs=${3:-}
  if [ -n "$secs" ] && [ "$secs" -gt 0 ] 2>/dev/null && command -v timeout >/dev/null 2>&1; then
    (cd "$project" 2>/dev/null && timeout "$secs" treehouse get --lease --lease-holder "$holder" 2>/dev/null)
  else
    (cd "$project" 2>/dev/null && treehouse get --lease --lease-holder "$holder" 2>/dev/null)
  fi
}

# fm_pool_warm_timeout: the ceiling on ONE warm, in seconds. Default 1800 - over
# 13x the measured 137s cold optiroq install, so a legitimately slow project is
# never cut short, while a genuinely hung one cannot hold the pool forever.
fm_pool_warm_timeout() {
  local secs="${FM_POOL_WARM_TIMEOUT:-}"
  case "$secs" in
    ''|*[!0-9]*) printf '1800' ;;
    *) printf '%s' "$secs" ;;
  esac
}

# fm_pool_boot_id: an identifier that CHANGES on every reboot. A pid alone is not
# an identity for anything that outlives a boot: the warm lock lives under
# ~/.treehouse and survives reboot, so a recorded pid can be re-used by an
# unrelated live process afterwards - making a long-dead warmer look alive forever.
# Linux exposes a real boot id; elsewhere, fall back to the boot time from uptime,
# and finally to a constant (which degrades to pid-only, never worse than before).
fm_pool_boot_id() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    tr -d '[:space:]' < /proc/sys/kernel/random/boot_id
  elif [ -r /proc/stat ] && grep -q '^btime' /proc/stat 2>/dev/null; then
    sed -n 's/^btime[[:space:]]*//p' /proc/stat | head -n 1 | tr -d '[:space:]'
  else
    printf 'no-boot-id'
  fi
}

# --- the pool lock ----------------------------------------------------------
#
# ONE warmer per pool (secondmate homes share pools; two warmers racing
# over-provision by GBs). Two implementations, because the guarantee is worth the
# code:
#
# flock (default, and what this box and CI have). The kernel owns the lock and
#   RELEASES IT WHEN THE HOLDER DIES - crash, SIGKILL, reboot, all of it. That
#   removes the whole class of bug the alternative keeps re-inventing: there is no
#   stale lock to reclaim, so there is no reclaim race, and no need to ask whether
#   a recorded pid is still the process that recorded it.
#
# directory + pid + boot id (fallback where flock is absent, e.g. stock macOS).
#   Here a stale lock is real and MUST be reclaimed, or one crash disables a pool's
#   warming forever. But the naive reclaim (`rm -rf` then `mkdir`) is a TOCTOU that
#   creates exactly the two warmers the lock prevents: both contenders judge the
#   owner dead; A recreates the lock and starts warming; B - still acting on its own
#   stale judgement - removes A's LIVE lock and takes its own. Renaming instead of
#   removing does not fix it either: the rename targets the PATH, and by then that
#   path holds A's new lock. So the right to reclaim is itself taken atomically
#   (mkdir of a reclaim dir), and only its winner may touch the lock.
#   Liveness there is pid AND boot id: the lock outlives a reboot, so a bare pid can
#   be recycled by an unrelated process - which would make a long-dead warmer look
#   alive forever, wedging the pool AND suppressing its leaked-lease report.
#
# FM_POOL_LOCK_FORCE_DIR=1 selects the fallback explicitly (the tests exercise both).

fm_pool_lock_use_flock() {
  [ "${FM_POOL_LOCK_FORCE_DIR:-0}" = 1 ] && return 1
  command -v flock >/dev/null 2>&1
}

# fm_pool_lock_acquire <lock-base>: returns 0 iff THIS process now holds the pool
# lock. Must run in the caller's own shell (it keeps an open fd).
fm_pool_lock_acquire() {  # <lock-base>
  local base=$1 reclaim
  mkdir -p "$(dirname "$base")" 2>/dev/null || return 1

  if fm_pool_lock_use_flock; then
    exec {FM_POOL_LOCK_FD}>"$base.lock" 2>/dev/null || return 1
    if flock -n "$FM_POOL_LOCK_FD" 2>/dev/null; then
      return 0
    fi
    exec {FM_POOL_LOCK_FD}>&- 2>/dev/null || true
    FM_POOL_LOCK_FD=
    return 1
  fi

  fm_pool_lock_claim_dir "$base" && return 0
  fm_pool_owner_alive "$base" && return 1     # a live warmer owns this pool

  # Stale. Take the RIGHT to reclaim atomically; only its winner may touch the lock.
  reclaim="$base.reclaim"
  mkdir "$reclaim" 2>/dev/null || return 1
  if fm_pool_owner_alive "$base"; then        # re-check under the reclaim lock
    rmdir "$reclaim" 2>/dev/null || true
    return 1
  fi
  rm -rf "$base" 2>/dev/null || true
  local rc
  fm_pool_lock_claim_dir "$base"
  rc=$?
  rmdir "$reclaim" 2>/dev/null || true
  return $rc
}

fm_pool_lock_claim_dir() {  # <lock-base>
  local base=$1
  mkdir "$base" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$base/pid" 2>/dev/null || true
  fm_pool_boot_id > "$base/boot" 2>/dev/null || true
  FM_POOL_LOCK_HELD=$base
  return 0
}

fm_pool_lock_release() {
  if [ -n "${FM_POOL_LOCK_FD:-}" ]; then
    exec {FM_POOL_LOCK_FD}>&- 2>/dev/null || true   # the kernel drops the flock
    FM_POOL_LOCK_FD=
  fi
  if [ -n "${FM_POOL_LOCK_HELD:-}" ]; then
    rm -rf "$FM_POOL_LOCK_HELD" 2>/dev/null || true
    FM_POOL_LOCK_HELD=
  fi
}

# fm_pool_warmer_live <lock-base>: is a warmer working this pool RIGHT NOW?
# Used by fm-pool-status.sh to decide whether a held warm lease is a warmer doing
# its job or a lease leaked by a dead one. Under flock this is exact: if we can
# take the lock, nobody holds it.
fm_pool_warmer_live() {  # <lock-base>
  local base=$1 fd
  if fm_pool_lock_use_flock; then
    [ -e "$base.lock" ] || return 1
    exec {fd}>"$base.lock" 2>/dev/null || return 1
    if flock -n "$fd" 2>/dev/null; then
      flock -u "$fd" 2>/dev/null || true
      exec {fd}>&- 2>/dev/null || true
      return 1                                 # we took it: no live warmer
    fi
    exec {fd}>&- 2>/dev/null || true
    return 0                                   # someone holds it
  fi
  fm_pool_owner_alive "$base"
}

# fm_pool_owner_alive <lock-dir>: is the warmer that took this lock still running?
# TRUE only when the recorded pid is alive AND was recorded on THIS boot. Anything
# else - no pid, dead pid, a pid from a previous boot (so possibly recycled), or an
# unreadable lock - is not a live owner, and the lock is reclaimable.
# Getting this wrong in the "alive" direction is the expensive one: it wedges a
# pool's warming permanently and hides its leaked lease from the report.
fm_pool_owner_alive() {  # <lock-dir>
  local lock=$1 pid boot
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  case "${pid:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  boot=$(cat "$lock/boot" 2>/dev/null || true)
  # No boot marker: written by an older version, or unreadable. Treat as a previous
  # boot - reclaimable - rather than trusting a bare pid across an unknown span.
  [ -n "$boot" ] || return 1
  [ "$boot" = "$(fm_pool_boot_id)" ]
}

# fm_pool_leased_by <project-real-path> <holder>: the slot path treehouse says is
# leased by <holder>, or empty.
# This is what makes a mid-install kill recoverable. `treehouse get --lease` marks
# the lease BEFORE it runs post_create and only prints the path at the END, so a
# warmer killed during the install (a reboot) holds a real lease whose path it
# never learned - and could not release it by path even though it must. treehouse's
# own status reports the holder, so ask it.
fm_pool_leased_by() {  # <project-real-path> <holder>
  local project=$1 holder=$2 slot state path lease
  fm_pool_read "$project" || return 0
  while IFS=$(printf '\t') read -r slot state path lease; do
    [ -n "${slot:-}" ] || continue
    [ "$state" = leased ] || continue
    [ "$lease" = "$holder" ] || continue
    printf '%s' "$path"
    return 0
  done <<EOF
$FM_POOL_TABLE
EOF
  return 0
}

# fm_pool_release <project-real-path> <slot-path>: release the lease. The slot's
# installed dependencies SURVIVE this (treehouse's reset is `git clean -fd`, no
# -x, so gitignored trees are kept) - which is what leaves it available AND warm.
fm_pool_release() {  # <project-real-path> <slot-path>
  (cd "$1" 2>/dev/null && treehouse return "$2" >/dev/null 2>&1)
}
