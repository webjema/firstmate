#!/usr/bin/env bash
# fm-taskstate-lib.sh - THE single owner of "which volatile state files encode a
# crew's LIVENESS", so the two callers that stop supervising a still-existing
# worktree clear exactly the same set and cannot drift apart:
#
#   1. bin/fm-teardown.sh's release_supervision_state - PR-open workspace release,
#      which drops window=, disowns the returned worktree (worktree= becomes
#      released_worktree=), and keeps the CI/merge watch.
#   2. bin/fm-detach.sh - hands a live crew to the user, which drops window=
#      and keeps the worktree for later reclaim.
#
# Both keep state/<id>.meta (each rewrites it with its own marker: released= or
# detached=) and both stop the watcher seeing the task by dropping window= from
# that meta. What they clear is identical: everything the crew-liveness machinery
# (bin/fm-watch.sh signal/stale/turn-end/decision/worktree-snapshot paths) keys
# on, INCLUDING the watcher's own per-task markers. The status file and turn-end
# tokens go because there is no crew to report; the .wt-* snapshots go because
# the next thing to touch this worktree starts a fresh activity baseline; the
# watcher markers go because the window they are keyed on is about to stop
# existing as far as supervision is concerned.
#
# Deliberately NOT cleared here: state/<id>.check.sh and state/<id>.ci-seen (the
# PR watch, which release KEEPS and which detach never created) and the meta
# itself (each caller rewrites it). full teardown removes those separately.
set -u

# fm_clear_crew_liveness_state <state-dir> <id> [window-target]: remove every
# per-task file that encodes crew liveness, leaving the meta and any PR watch
# untouched. Idempotent; missing files are fine.
#
# PASS THE WINDOW TARGET whenever the caller still knows it. The watcher's own
# markers are the one part of this set keyed on something OTHER than the bare
# task id: bin/fm-watch.sh keys its pane-staleness family on the WINDOW target
# with ':/.' folded to '_', and its signal scan on the status/turn-end file
# BASENAME with '.' folded to '_'. Both derivations are rebuilt below exactly as
# the watcher builds them, because a wrong key means the file simply survives
# forever. Both callers above drop window= from the meta immediately after
# calling in, so this is the LAST moment the window-keyed family is addressable
# at all. An omitted or empty window skips just that family - correct for a meta
# that never had a window, or has already lost it.
fm_clear_crew_liveness_state() {  # <state-dir> <id> [window-target]
  local state=$1 id=$2 win=${3:-} tid key
  tid=$(printf '%s' "$id" | tr ':/.' '___')
  rm -f \
    "$state/$id.status" \
    "$state/$id.turn-ended" \
    "$state/$id.pi-ext.ts" \
    "$state/$id.grok-turnend-token" \
    "$state/.turnend-seen-$id" \
    "$state/.decision-seen-$id" \
    "$state/.wt-size-$id" \
    "$state/.wt-snap-$id" \
    "$state/.wt-since-$id" \
    "$state/.wt-still-woke-$id" \
    "$state/.hb-surfaced-$tid" \
    "$state/.seen-${tid}_status" \
    "$state/.seen-${tid}_turn-ended"
  [ -n "$win" ] || return 0
  key=$(printf '%s' "$win" | tr ':/.' '___')
  rm -f \
    "$state/.hash-$key" \
    "$state/.count-$key" \
    "$state/.stale-$key" \
    "$state/.stale-since-$key" \
    "$state/.wedge-escalations-$key" \
    "$state/.paused-$key" \
    "$state/.paused-rechecked-$key" \
    "$state/.paused-resurfaced-$key"
}
