#!/usr/bin/env bash
# fm-pool-status.sh - notice when a project's treehouse pool has silently shrunk.
# Prints one line per unusable slot and exits 0. SILENT = every pool is healthy.
#
# Usage: fm-pool-status.sh            every project under projects/
#        fm-pool-status.sh <project>  one project (a name under projects/, or a path)
#
# THE INCIDENT THIS EXISTS FOR (2026-07-14). The box rebooted mid-task three
# times. Each crash left the crew's slot DIRTY - uncommitted work still in it -
# and, verified against treehouse v2.0.0:
#
#   * `treehouse get` SKIPS a dirty slot. Forever. It is never handed out again.
#   * `treehouse prune` REFUSES to reclaim it: "Skipped 1 unsafe idle worktree:
#     uncommitted changes".
#
# So the pool silently shrank, nothing noticed, and eventually every remaining
# slot was in use and spawning failed. A human found it by looking. This script
# is firstmate looking, at session start, every time - which is the point of
# "firstmate must know its own pool's state instead of discovering exhaustion as
# a timeout".
#
# IT NEVER DISCARDS ANYTHING. A dirty slot may hold a dead crew's unlanded work -
# today's did, and it was salvaged and shipped. So this DETECTS and REPORTS, with
# the evidence (uncommitted file count, unpushed commits) and the exact commands.
# Reclaiming is the user's decision, never a sweep. This is the same
# fail-closed posture bin/fm-teardown.sh takes toward unlanded work, for the same
# reason: the cost of a wrong "discard" is unrecoverable, the cost of a wrong
# "report" is one line of output.
#
# Lines (formats owned here; the bootstrap-diagnostics skill owns the response):
#   POOL_SLOT: <project>: slot <name> is DIRTY[, holds <evidence>] - `treehouse get`
#     skips it forever and `treehouse prune` will not reclaim it. Inspect: <cmd>.
#     Reclaim (DISCARDS the work): <cmd>
#   POOL_SLOT: <project>: slot <name> is LEASED by <holder> with no live warmer -
#     a warmer died mid-install and the slot is reserved forever. Release: <cmd>
#   POOL_SLOT: <project>: slot <name> is ORPHANED (owner pid <pid> is gone) - <cmd>
#   POOL_BUDGET: <project>: <reason>   (raised by bin/fm-pool-warm.sh, surfaced here)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TREEHOUSE_ROOT="${FM_TREEHOUSE_ROOT:-$HOME/.treehouse}"

# shellcheck source=bin/fm-pool-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pool-lib.sh"

# Evidence for the user's reclaim decision. Deliberately READ-ONLY, and
# deliberately honest when it cannot tell: an unreadable worktree reports no
# evidence rather than a reassuring "clean".
slot_evidence() {  # <slot-path>
  local path=$1 files commits evidence=""
  git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || return 0
  files=$(git -C "$path" status --porcelain 2>/dev/null | grep -c . || true)
  if [ "${files:-0}" -gt 0 ]; then
    evidence="$files uncommitted file(s)"
  fi
  # Commits on this worktree's HEAD that exist on no remote-tracking branch: the
  # dead crew's work that a discard would destroy. Same question fm-teardown.sh
  # asks before it lets a worktree go.
  # HEAD, deliberately, not --branches: treehouse checks a slot out DETACHED, so a
  # crew that committed without branching has work that --branches cannot see. Any
  # under-report here reads as "nothing to lose" on a slot that has plenty.
  commits=$(git -C "$path" log --oneline HEAD --not --remotes 2>/dev/null | grep -c . || true)
  if [ "${commits:-0}" -gt 0 ]; then
    [ -n "$evidence" ] && evidence="$evidence and "
    evidence="${evidence}${commits} unpushed commit(s)"
  fi
  printf '%s' "$evidence"
}

# A firstmate warm lease (bin/fm-pool-warm.sh) is transient: taken, install, then
# released within one warm cycle. One still held with no live warmer owning the
# pool lock means the warmer died mid-install (a reboot), and the slot is
# reserved forever. Unlike a dirty slot, this holds NO work: releasing it is safe
# and non-destructive, so the command we print is a plain `treehouse return`.
#
# Liveness is boot-aware (fm_pool_owner_alive), never a bare `kill -0` on a
# recorded pid: the lock survives reboot, so after a restart that pid may belong to
# an unrelated live process - and a false "the warmer is still working" would
# SUPPRESS this very report, leaving the leaked lease permanent and invisible.
warmer_is_live() {  # <project-real-path>
  fm_pool_warmer_live "$TREEHOUSE_ROOT/.fm-warm-locks/$(fm_pool_key "$1")"
}

# treehouse's own state file records an owner_pid for a slot handed out without a
# lease. A recorded owner that is GONE, on a slot treehouse still reports as
# in-use, is an orphan: the crew died and its reservation outlived it.
orphaned_owner_pid() {  # <pool-dir> <slot-path>
  local pool_dir=$1 slot=$2 pid
  [ -n "$pool_dir" ] || return 1
  [ -f "$pool_dir/treehouse-state.json" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  pid=$(jq -r --arg p "$slot" \
    '.worktrees[]? | select(.path == $p) | .owner_pid // empty' \
    "$pool_dir/treehouse-state.json" 2>/dev/null | head -n 1)
  case "${pid:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null && return 1   # owner alive: not an orphan
  printf '%s' "$pid"
}

report_project() {  # <project-real-path>
  local project=$1 name line slot state path holder evidence pid
  name=$(basename "$project")

  # Read-only means read-only: `treehouse status` CREATES a project's pool
  # directory just by being asked (verified 2026-07-14), so a session-start sweep
  # over every project would leave an empty pool behind for each one. A project with
  # no slots has nothing to diagnose anyway (fm_pool_has_slots).
  fm_pool_has_slots "$project" || return 0
  fm_pool_read "$project" || return 0

  # A blocked warm (disk budget, max_trees) is a capacity fact raised by
  # fm-pool-warm.sh and surfaced HERE, at session start - never as a mid-flight
  # wake. The user decides; firstmate does not silently fill the disk.
  #
  # Self-healing: the warmer only clears its own sentinel while it is still warming
  # that project, so a pool that has since freed up - the task finished, a slot was
  # reclaimed - would otherwise reprint a stale block at every session start
  # forever. If the pool now HAS a free warm slot, the block is over: drop it.
  local sentinel
  sentinel="$STATE/.pool-warm-blocked.$(fm_pool_key "$project")"
  if [ -f "$sentinel" ]; then
    if [ "$FM_POOL_AVAILABLE" -ge 1 ]; then
      rm -f "$sentinel" 2>/dev/null || true
    else
      printf 'POOL_BUDGET: %s: %s\n' "$name" "$(cat "$sentinel" 2>/dev/null)"
    fi
  fi

  while IFS=$(printf '\t') read -r slot state path holder; do
    [ -n "${slot:-}" ] || continue
    case "$state" in
      dirty)
        evidence=$(slot_evidence "$path")
        [ -n "$evidence" ] && evidence=", holds $evidence"
        printf 'POOL_SLOT: %s: slot %s is DIRTY%s - treehouse get skips it forever and treehouse prune will not reclaim it. Inspect first: git -C %s status. Reclaim (DISCARDS any work in it): treehouse destroy %s --include-unlanded --yes\n' \
          "$name" "$slot" "$evidence" "$path" "$path"
        ;;
      leased)
        case "$holder" in
          fm-warm-*)
            warmer_is_live "$project" && continue
            printf 'POOL_SLOT: %s: slot %s is LEASED by %s with no live warmer - a warm died mid-install and the slot is reserved forever. Release it (safe, holds no work): treehouse return %s\n' \
              "$name" "$slot" "$holder" "$path"
            ;;
        esac
        ;;
      in-use)
        pid=$(orphaned_owner_pid "$FM_POOL_DIR" "$path") || continue
        printf 'POOL_SLOT: %s: slot %s is ORPHANED (its owner pid %s is gone) but still reserved - inspect it before reclaiming: git -C %s status\n' \
          "$name" "$slot" "$pid" "$path"
        ;;
    esac
  done <<EOF
$FM_POOL_TABLE
EOF
}

if [ -n "${1:-}" ]; then
  if [ -d "$1" ]; then
    proj=$(cd "$1" && pwd -P)
  elif [ -d "$PROJECTS/$1" ]; then
    proj=$(cd "$PROJECTS/$1" && pwd -P)
  else
    echo "error: no such project: $1" >&2
    exit 1
  fi
  report_project "$proj"
  exit 0
fi

# WHICH POOLS TO SWEEP. Every clone under projects/ - a dirty slot left by a crew
# that died OUTLIVES its task, so an in-flight-only sweep would miss exactly the
# case that went unnoticed - PLUS every project named by a task meta.
#
# That second source is not a nicety. A crewmate working on FIRSTMATE ITSELF has
# project=<the firstmate root>, which is NOT under projects/ - so a projects/-only
# sweep is blind to the firstmate pool. That is the pool every firstmate crewmate
# runs in, and it is the pool whose crash-dirty slot motivated this script. It must
# be swept, or the detector cannot see the incident it was written for.
seen=""
report_unique() {  # <project-path>
  local p=$1 real
  [ -d "$p" ] || return 0
  git -C "$p" rev-parse --git-dir >/dev/null 2>&1 || return 0
  real=$(cd "$p" && pwd -P) || return 0
  case " $seen " in *" $real "*) return 0 ;; esac
  seen="$seen $real"
  report_project "$real"
}

if [ -d "$PROJECTS" ]; then
  for p in "$PROJECTS"/*; do
    report_unique "$p"
  done
fi
if [ -d "$STATE" ]; then
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    proj=$(sed -n 's/^project=//p' "$meta" | head -n 1)
    [ -n "$proj" ] && report_unique "$proj"
  done
fi
exit 0
