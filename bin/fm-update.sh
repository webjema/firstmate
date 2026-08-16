#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home (each a treehouse worktree of this same repo, or
# a standalone clone) the same way. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Secondmate homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several.
#
# It REFUSES outright while another firstmate instance sharing this checkout is
# live, and takes the per-clone write lock for the fast-forward itself; see the
# refusal below and bin/fm-peer-lib.sh.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-peer-lib.sh
. "$SCRIPT_DIR/fm-peer-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- refuse while a peer instance is mid-turn ------------------------------
#
# Under one shared checkout, fast-forwarding $FM_ROOT swaps bin/ beneath every
# other instance running from it, mid-turn. An update is never urgent and a live
# peer is a reason to wait, not a race to win, so this refuses and names the
# peers. bin/fm-peer-lib.sh owns how a peer is discovered and how its liveness is
# decided, and only peers on THIS checkout count - a secondmate runs its own, and
# updating it is this script's job rather than a reason to refuse. With no peers -
# the single-instance arrangement, and every instance started before it announced
# itself - nothing here fires.

peers=$(fm_peer_live_homes "$FM_ROOT" "$STATE")
if [ -n "$peers" ]; then
  echo "error: another firstmate instance is live on this checkout ($FM_ROOT); not swapping bin/ under it" >&2
  printf '%s\n' "$peers" | while IFS= read -r peer; do
    [ -n "$peer" ] || continue
    echo "  peer home: $peer   (see it with: FM_HOME=$peer $SCRIPT_DIR/fm-lock.sh status)" >&2
  done
  echo "retry once they are done, or update from the instance that owns them" >&2
  exit 1
fi

# --- main firstmate repo ---------------------------------------------------
#
# Under the per-clone lock too: two instances updating the same checkout at once
# is the same shared-writer race fm-fleet-sync.sh takes it for.

# The lock is held in a SUBSHELL, so ff_target's FF_STATUS/FF_INSTR do not survive
# it; the verdict rides back as an exit code instead of a temp file.
reread_firstmate="no"
update_root() {
  ff_target "$FM_ROOT" "firstmate" origin no no
  [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ] && return 10
  return 0
}
rc=0
fm_clone_lock_run "$FM_ROOT" update_root || rc=$?
case "$rc" in
  0) ;;
  10) reread_firstmate="yes" ;;
  75)
    echo "error: another firstmate instance has held this checkout for over $(fm_clone_lock_wait_secs)s; nothing was updated" >&2
    exit 1
    ;;
  *) exit "$rc" ;;
esac

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin no

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    id=$(printf '%s\n' "$line" | sed -n 's/^- \([^ ][^ ]*\) - .*/\1/p')
    home=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')
    process_secondmate "$id" "$home" "" origin no
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
