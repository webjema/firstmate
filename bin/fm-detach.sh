#!/usr/bin/env bash
# Hand a live crew to the captain, then reclaim its worktree once the captain is
# done - the two halves of "you started it, now I want to drive it myself".
#
# WHY THIS EXISTS. firstmate watches a task ONLY because state/<id>.meta carries a
# window= line: bin/fm-watch.sh's recorded_windows() and recovery both key off it.
# Ordinary teardown severs that tie by DESTROYING the worktree, which is the wrong
# tool when the crew's window should stay alive for the captain. Detach severs only
# the SUPERVISION tie: it drops window= (so the watcher and recovery stop treating
# the task as a crew - see AGENTS.md recovery, which skips a detached meta exactly
# as it skips a released one), stamps detached=, and remembers the window under
# detached_window= for the later liveness probe. The tmux window and the worktree
# are left untouched; the captain now owns both.
#
# Usage:
#   fm-detach.sh <id>                 hand crew <id> to the captain
#   fm-detach.sh --reclaim <id>       return <id>'s worktree to the pool if idle
#   fm-detach.sh --reclaim            reclaim every detached task that is idle
#   fm-detach.sh --reclaim --force <id>   reclaim without the idle gate (captain
#                                         confirms the session is done)
#
# RECLAIM is deliberately just an idle gate in front of ordinary teardown, so the
# landed-work safety that protects unlanded work is reused verbatim, never
# re-implemented:
#   1. Idle gate. The captain's session is "done" when the detached window is gone,
#      or still present but sitting at a bare shell (fm_backend_agent_alive => dead).
#      An alive or ambiguous (unknown) agent is NOT reclaimed - the same dead-only
#      rule the secondmate-liveness sweep uses, so a momentary read glitch can never
#      pull a worktree out from under a live session. --force skips this gate.
#   2. Delegate to bin/fm-teardown.sh <id>. With window= already dropped this is a
#      full teardown: it REFUSES if the worktree holds uncommitted or unlanded work
#      (rule 3), returns the treehouse slot, and purges the meta. A refusal here is
#      the captain's unfinished work being protected, not a failure to route around.
# Detach never reclaims and reclaim never detaches; the split keeps each idempotent.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-taskstate-lib.sh
. "$SCRIPT_DIR/fm-taskstate-lib.sh"

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- detach ------------------------------------------------------------------

detach_one() {  # <id>
  local id=$1 meta window worktree kind backend tmp
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { echo "error: no task $id at $meta" >&2; return 1; }

  window=$(fm_meta_get "$meta" window)
  if [ -z "$window" ]; then
    echo "error: task $id has no live crew window (already detached, released, or torn down); nothing to hand over" >&2
    return 1
  fi

  kind=$(fm_meta_get "$meta" kind); [ -n "$kind" ] || kind=ship
  if [ "$kind" = secondmate ]; then
    echo "error: task $id is a secondmate; retire it with fm-teardown.sh, not detach" >&2
    return 1
  fi

  worktree=$(fm_meta_get "$meta" worktree)
  backend=$(fm_backend_of_meta "$meta")

  # Rewrite the meta atomically: drop window= (watcher/recovery now ignore it),
  # remember the window for the reclaim liveness probe, and stamp detached=.
  tmp=$(mktemp "$STATE/.$id.meta.XXXXXX") || return 1
  grep -v '^window=' "$meta" > "$tmp"
  {
    printf 'detached=%s\n' "$(now_utc)"
    printf 'detached_window=%s\n' "$window"
  } >> "$tmp"
  mv "$tmp" "$meta"

  fm_clear_crew_liveness_state "$STATE" "$id"

  echo "detached $id: the crew window ($window) is now yours to drive; its worktree ($worktree) is untouched."
  echo "When you are done, close that window and I will return the slot to the pool (or run: fm-detach.sh --reclaim $id)."
  echo "Backlog: move $id out of In flight - it is captain-managed now, not a firstmate task."
}

# --- reclaim -----------------------------------------------------------------

# is_idle <backend> <window>: 0 when the detached session is done (window gone, or
# present but a bare shell), 1 when a live/ambiguous agent means leave it alone.
is_idle() {  # <backend> <window>
  local backend=$1 window=$2 alive
  [ -n "$window" ] || return 0
  fm_backend_target_exists "$backend" "$window" || return 0
  alive=$(fm_backend_agent_alive "$backend" "$window")
  [ "$alive" = dead ]
}

reclaim_one() {  # <id> <force>
  local id=$1 force=$2 meta detached window worktree backend
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { echo "error: no task $id at $meta" >&2; return 1; }

  detached=$(fm_meta_get "$meta" detached)
  if [ -z "$detached" ]; then
    echo "error: task $id is not detached (no detached= marker); nothing to reclaim" >&2
    return 1
  fi

  window=$(fm_meta_get "$meta" detached_window)
  worktree=$(fm_meta_get "$meta" worktree)
  backend=$(fm_backend_of_meta "$meta")

  if [ "$force" != "--force" ] && ! is_idle "$backend" "$window"; then
    echo "reclaim $id: still open in your session ($window); close it - or reclaim with --force - and I will return the slot."
    return 0
  fi

  # The session is done: drop any leftover shell window teardown will not (window=
  # is already gone from the meta), then let teardown do the safe return + purge.
  [ -n "$window" ] && fm_backend_kill "$backend" "$window" 2>/dev/null || true

  if "$FM_ROOT/bin/fm-teardown.sh" "$id"; then
    echo "reclaimed $id: worktree ($worktree) returned to the pool and the task closed out."
    return 0
  fi
  echo "reclaim $id: could not return the worktree ($worktree) - most likely it holds uncommitted or unlanded work, which teardown protects. Land or discard it, then reclaim again." >&2
  return 1
}

reclaim_all() {  # <force>
  local force=$1 meta id any=0 rc=0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ -n "$(fm_meta_get "$meta" detached)" ] || continue
    any=1
    id=$(basename "$meta" .meta)
    reclaim_one "$id" "$force" || rc=1
  done
  [ "$any" = 1 ] || echo "reclaim: no detached tasks to reclaim."
  return "$rc"
}

# --- dispatch ----------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --reclaim)
    shift
    "$FM_ROOT/bin/fm-guard.sh" || true
    FORCE=""
    if [ "${1:-}" = --force ]; then FORCE=--force; shift; fi
    if [ -n "${1:-}" ]; then reclaim_one "$1" "$FORCE"; else reclaim_all "$FORCE"; fi
    ;;
  ''|-*)
    usage >&2; exit 2 ;;
  *)
    "$FM_ROOT/bin/fm-guard.sh" || true
    detach_one "$1"
    ;;
esac
