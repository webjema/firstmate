#!/usr/bin/env bash
# Write the turn-end marker with a BODY. Invoked by every harness's per-task
# turn-end hook (bin/fm-spawn.sh installs them); replaces the payload-free
# `touch state/<id>.turn-ended` those hooks used to run.
#
# Usage: fm-turnend-mark.sh <turn-ended-path> [<worktree>]
#
# A content-free touch told the watcher only THAT a turn ended, never whether the
# turn accomplished anything - so every no-verb turn end cost a pane probe, and an
# idle crew that had merely finished a subtask cost firstmate a 40-line peek. The
# body is that missing evidence, one line:
#
#   turn=<n> head=<sha|none> idx=<epoch> edit=<epoch> dirty=<n|?>
#
#   turn=  how many turns this crew has ended. Counted HERE, by incrementing the
#          previous marker's value: no verified harness turn-end hook supplies a
#          turn number (claude's Stop payload carries session_id, transcript_path,
#          cwd, prompt_id, permission_mode, effort, hook_event_name,
#          stop_hook_active, last_assistant_message, background_tasks,
#          session_crons - and nothing else; see docs/turnend-guard.md for how the
#          other harnesses' payloads were captured). Fields no harness actually
#          provides - last tool used, an exit reason - are deliberately ABSENT
#          rather than invented.
#   the rest is bin/fm-wt-activity-lib.sh's worktree snapshot, which owns those
#          fields: what the crew did to the WORK during the turn.
#
# The marker is REWRITTEN, not appended: the watcher's signal scan keys on the
# file's size:mtime signature, and one line keeps it a marker rather than a log.
# Every failure path still writes the file (an empty body reads as "no evidence",
# and the watcher falls back to its pane probe exactly as before), and this script
# always exits 0: a turn-end hook must never fail its harness's turn.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
# shellcheck source=bin/fm-wt-activity-lib.sh
. "$SCRIPT_DIR/fm-wt-activity-lib.sh" 2>/dev/null || exit 0

TURNEND=${1:-}
WT=${2:-}
[ -n "$TURNEND" ] || exit 0

prev=$(head -1 "$TURNEND" 2>/dev/null || true)
turn=0
case "$prev" in
  turn=*)
    turn=${prev#turn=}
    turn=${turn%% *}
    ;;
esac
case "$turn" in ''|*[!0-9]*) turn=0 ;; esac
turn=$((turn + 1))

snap=$(wt_activity_snapshot "$WT" 2>/dev/null || true)

tmp="$TURNEND.tmp.$$"
if [ -n "$snap" ]; then
  printf 'turn=%s %s\n' "$turn" "$snap" > "$tmp" 2>/dev/null || exit 0
else
  printf 'turn=%s\n' "$turn" > "$tmp" 2>/dev/null || exit 0
fi
mv -f "$tmp" "$TURNEND" 2>/dev/null || rm -f "$tmp" 2>/dev/null
exit 0
