# shellcheck shell=bash
# fm-detach-lib.sh - THE single owner of "is this task DETACHED?".
# Usage: . bin/fm-detach-lib.sh
#
# A detached task is one bin/fm-detach.sh handed to the user: it stamped
# `detached=` into state/<id>.meta, and AGENTS.md section 6 states what that means
# - detach "severs only supervision: the crew's window and worktree stay alive for
# the user, but the watcher and recovery stop tracking it". Every reader of that
# rule reads it through here, so the watcher's wake suppression
# (bin/fm-watch.sh's signal scan, bin/fm-classify-lib.sh's captain-relevant scan)
# and the guards' supervisable count (bin/fm-supervision-lib.sh) cannot drift into
# disagreeing about which tasks firstmate is answerable for.
#
# Presence of the marker is the WHOLE test, re-read from the meta on every call
# rather than cached: stamping it must stop the wakes without restarting the
# watcher, and clearing it must restore them the same way - clearing the marker is
# the only path back to supervision there is.
#
# Suppress the WAKE, never the RECORDING. bin/fm-detach.sh --reclaim gates on
# detached=, detached_window= and worktree= from this same meta, and the crew's
# status and turn-end files keep being written by the session the user is driving.
# Nothing keyed on this predicate may stop any of that being written or kept.
#
# Not everything a detached task can raise is suppressed, and one exclusion is
# deliberate: state/<id>.check.sh. bin/fm-detach.sh leaves a PR watch armed before
# the hand-over reporting, exactly as release does, so the watcher's check sweep
# stays unfiltered by design and must not be "fixed" to consult this predicate.

# fm_meta_is_detached <meta-file>: 0 when the meta carries a detached= marker.
# A missing or unreadable meta is NOT detached: a signal from a task firstmate has
# no record of is exactly the kind it must still wake for.
fm_meta_is_detached() {  # <meta-file>
  grep -q '^detached=' "$1" 2>/dev/null
}

# fm_task_is_detached <state-dir> <id>: the same test, by task id.
fm_task_is_detached() {  # <state-dir> <id>
  fm_meta_is_detached "$1/$2.meta"
}
