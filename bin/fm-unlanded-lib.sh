# shellcheck shell=bash
# The one definition of "committed in this worktree, delivered nowhere".
# Usage: . bin/fm-unlanded-lib.sh   (needs nothing set beforehand)
#
# Two scripts ask that question and must never disagree about the answer:
#   - bin/fm-teardown.sh, which refuses to remove a worktree that still holds work.
#   - bin/fm-pool-status.sh, which reports what a slot would lose, directly above
#     the command that would discard it.
# Each carried its own copy until the post-commit backup hook in
# bin/fm-hooks-install.sh began writing refs/remotes/*/wip/*, at which point a
# plain --not --remotes reads a BACKUP as a delivery. An under-report costs a
# worktree, so the exclusion lives here rather than once per caller.
#
# THE PATTERN HAS NO refs/remotes/ PREFIX ON PURPOSE. For --remotes, git matches
# an --exclude pattern against the ref name with refs/remotes/ ALREADY STRIPPED,
# so a refs/remotes/*/wip/* spelling matches nothing at all - silently, with no
# error, excluding nothing. Never "clarify" it by restoring the prefix. Its `*`
# crosses `/`, which is what lets one `*` cover a branch name containing slashes.
#
# It is deliberately coarser than the hook's own wip/<host>/<branch> layout, so a
# real user branch named wip/anything is excluded too. That is the safe direction
# to be wrong in: the exclusion only shrinks the set of refs work can hide behind,
# which makes both callers more conservative, never less. tests/fm-teardown.test.sh
# pins both directions.
WIP_BACKUP_GLOB='*/wip/*'

# git log's ref-set arguments for "not reachable from any non-backup remote ref".
# shellcheck disable=SC2034 # Read by callers (fm-teardown.sh, fm-pool-status.sh) after sourcing.
NOT_ON_A_REMOTE=(--not --exclude="$WIP_BACKUP_GLOB" --remotes)
