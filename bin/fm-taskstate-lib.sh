#!/usr/bin/env bash
# fm-taskstate-lib.sh - THE single owner of "which volatile state files encode a
# crew's LIVENESS", so the two callers that stop supervising a still-existing
# worktree clear exactly the same set and cannot drift apart:
#
#   1. bin/fm-teardown.sh's release_supervision_state - PR-open workspace release,
#      which drops window= and keeps the CI/merge watch.
#   2. bin/fm-detach.sh - hands a live crew to the user, which drops window=
#      and keeps the worktree for later reclaim.
#
# Both keep state/<id>.meta (each rewrites it with its own marker: released= or
# detached=) and both stop the watcher seeing the task by dropping window= from
# that meta. What they clear is identical: everything the crew-liveness machinery
# (bin/fm-watch.sh signal/stale/turn-end/decision/worktree-snapshot paths) keys
# on. The status file and turn-end tokens go because there is no crew to report;
# the .wt-* snapshots go because the next thing to touch this worktree starts a
# fresh activity baseline.
#
# Deliberately NOT cleared here: state/<id>.check.sh and state/<id>.ci-seen (the
# PR watch, which release KEEPS and which detach never created) and the meta
# itself (each caller rewrites it). full teardown removes those separately.
set -u

# fm_clear_crew_liveness_state <state-dir> <id>: remove every per-task file that
# encodes crew liveness, leaving the meta and any PR watch untouched. Idempotent;
# missing files are fine.
fm_clear_crew_liveness_state() {  # <state-dir> <id>
  local state=$1 id=$2
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
    "$state/.wt-still-woke-$id"
}
