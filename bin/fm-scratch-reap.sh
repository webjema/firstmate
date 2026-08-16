#!/usr/bin/env bash
# fm-scratch-reap.sh — reclaim orphaned harness scratchpad session dirs.
#
# WHY THIS EXISTS. The Claude Code harness gives each session a private scratch
# tree under /tmp/claude-<uid>/<cwd-encoded>/<session-id>/ (scratchpad, tasks,
# tool-results). firstmate tears down a crew's git worktree when its work lands,
# but it does NOT touch that crew's harness scratchpad, and a crew that dies
# without a clean teardown orphans it entirely. Browser-driven and verify-heavy
# crews leave hundreds of MB behind (Chrome profiles, extracted .deb/lib installs,
# image/PDF synthesis artifacts). The only backstop is systemd-tmpfiles at a
# 30-DAY age, so on a disk-backed /tmp (not tmpfs, so a reboot does not clear it)
# a dead crew's scratchpad sits for a month. This reaper is the firstmate-side
# cleanup: it deletes session scratch dirs that have been UNTOUCHED past a
# threshold, turning a month-long backlog into a rolling few-day cleanup.
#
# SAFETY MODEL. "Untouched for longer than the threshold" is the liveness proxy:
# a live or recently-active session writes into its scratch tree, so a tree with
# NO file modified within the window is a dead session. Four hard rails on top:
#   1. The root must match the harness pattern (basename claude-<digits>), so the
#      reaper can never be pointed at an arbitrary directory.
#   2. A --protect <substr> (repeatable) skips any session dir whose path matches,
#      so a caller that knows a live crew's worktree can guarantee it is spared
#      regardless of age.
#   3. --dry-run prints what it WOULD reap and deletes nothing.
#   4. The liveness probe FAILS CLOSED. Its three answers are alive, demonstrably
#      dead, and unanswered, and only a demonstrable death clears a deletion. See
#      probe_capability and has_recent_file below, and the next paragraph but one
#      for why "unanswered" is two different things.
# The current session's own scratch is naturally spared: it is being written to
# now, so its newest mtime is inside the window. Pass --self <id> to spare it by
# name as well.
#
# Rail 4 exists because its absence deleted live sessions. The probe used to be
# `find "$d" -type f -newermt "@$cutoff" -print -quit 2>/dev/null`, and both of
# those primaries are GNU-only. BSD find (macOS) rejects the @epoch form outright -
# "find: Can't parse date/time: @1785062658", exit 1, NO stdout - and with stderr
# discarded, an empty result read as "nothing recent here, safe to reap". So on
# macOS every session dir was reaped on every run regardless of age or liveness,
# including the scratch of the session doing the reaping, and including live crews'.
# It hid for so long because the `find` in an interactive Claude Code shell is a
# function shimming bfs, which accepts the GNU forms; only the script, running under
# bash with /usr/bin/find, ever saw the failure.
# The date syntax was just the trigger. The defect was deleting on an unanswered
# safety check, so the fix is both: a portable probe AND a refusal to act on doubt.
#
# TWO KINDS OF UNKNOWN, AND ONLY ONE OF THEM IS PERMANENT. Treating every non-zero
# find status as "unknown, spare forever" overshoots: one unreadable subdir, or a
# file another process removes mid-walk, exempted a session dir on every run from
# then on and scratch grew without bound behind an unexplained alarm. So the two
# are separated at their real boundary:
#   THE PROBE CANNOT RUN AT ALL - find is missing, or rejects the primary. That is
#     a property of the TOOL, identical for every directory, so it is established
#     ONCE up front (see probe_capability) and reaping stops entirely with a loud,
#     specific line. This is the case that deleted live sessions, and it is exactly
#     as fatal as before.
#   THE WALK HIT A BAD ENTRY while otherwise answering. Per-directory, transient,
#     and it does NOT mean the probe is broken. The dir is spared this run and named
#     in the output, so it is diagnosable rather than a bare count. A HARD CEILING
#     stops that from being forever: once the session dir's OWN mtime - which no
#     unreadable child can hide - is older than FM_SCRATCH_HARD_CEILING_MULTIPLE
#     times the window, a top-level directory untouched that long is not a live
#     session under any reading, and it is reaped with the reason printed.
#
# Usage: fm-scratch-reap.sh [options]
#   --root DIR             scratch root (default: /tmp/claude-<uid>;
#                          env FM_SCRATCH_ROOT). Must be named claude-<digits>.
#   --max-age-hours N      reap a session dir untouched for more than N hours
#                          (default 48; env FM_SCRATCH_MAX_AGE_HOURS). Must be
#                          positive: 0 would ask find for `-mmin -0`, which matches
#                          nothing, so every session dir including the live callers'
#                          would read as dead.
#   --protect SUBSTR       never reap a session dir whose path contains SUBSTR
#                          (repeatable; env FM_SCRATCH_PROTECT, whitespace-split)
#   --self ID              never reap a session dir whose path contains ID
#   --dry-run              print candidates, delete nothing (env FM_SCRATCH_DRY_RUN=1)
#   --verbose              print a summary even when nothing was reaped
#   -h|--help              this header
# Prints one "SCRATCH_REAP: ..." line per reaped (or would-reap) dir plus a
# summary line; stays silent on a clean sweep unless --verbose. Always exits 0
# unless given bad arguments: it is a best-effort janitor, never a gate.
set -u

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
}

ROOT="${FM_SCRATCH_ROOT:-/tmp/claude-$(id -u)}"
MAX_AGE_HOURS="${FM_SCRATCH_MAX_AGE_HOURS:-48}"
DRY_RUN="${FM_SCRATCH_DRY_RUN:-0}"
VERBOSE=0
PROTECT=()
# Seed protect list from the environment (whitespace-separated), if any.
if [ -n "${FM_SCRATCH_PROTECT:-}" ]; then
  # shellcheck disable=SC2206  # deliberate word-split: FM_SCRATCH_PROTECT is a whitespace-separated list of substrings.
  PROTECT=(${FM_SCRATCH_PROTECT})
fi

die() { echo "fm-scratch-reap: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a dir}"; shift 2 ;;
    --max-age-hours) MAX_AGE_HOURS="${2:?--max-age-hours needs a number}"; shift 2 ;;
    --protect) PROTECT+=("${2:?--protect needs a substring}"); shift 2 ;;
    --self) PROTECT+=("${2:?--self needs an id}"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

# A positive integer, and 0 is NOT a harmless edge: it becomes `-mmin -0`, which
# matches no file at all, so every session dir - the live callers' included - would
# come back "no recent file here, dead" and be deleted. Refuse it at the door.
case "$MAX_AGE_HOURS" in
  ''|*[!0-9]*) die "--max-age-hours must be a positive integer, got '$MAX_AGE_HOURS'" ;;
  # All-zero digits, "0" or "000": tested textually rather than arithmetically,
  # because $(( 08 )) is an octal error rather than the eight the caller meant.
  *[!0]*) ;;
  *) die "--max-age-hours must be greater than 0 (0 matches no file, so every session dir - live ones included - would read as dead)" ;;
esac

# Rail 1: only ever operate on a harness scratch root (basename claude-<digits>).
case "$(basename -- "$ROOT")" in
  claude-[0-9]*) ;;
  *) die "refusing: root '$ROOT' is not a claude-<uid> scratch root" ;;
esac
[ -d "$ROOT" ] || { [ "$VERBOSE" = 1 ] && echo "SCRATCH_REAP: root $ROOT absent, nothing to do"; exit 0; }

WINDOW_MINUTES=$(( MAX_AGE_HOURS * 60 ))
# How far past the window a session dir's OWN mtime must be before an unprobeable
# tree is reaped anyway. See the header's hard ceiling; 7 * 48h = two weeks by default.
HARD_CEILING_MULTIPLE="${FM_SCRATCH_HARD_CEILING_MULTIPLE:-7}"
CEILING_MINUTES=$(( WINDOW_MINUTES * HARD_CEILING_MULTIPLE ))

# probe_capability: can find answer a liveness question at all on this box? Asked
# ONCE, against the root itself at -maxdepth 0, so it stats exactly one directory
# that is known to exist and cannot fail for any reason except the tool. That is
# what separates "the probe is broken" - identical for every directory, and the
# defect that once deleted live sessions - from "one entry in one tree was
# unreadable". Sets QUIT_OK as a side effect.
#
# `-mmin` is the portable primary here: BSD and GNU find both accept it, it needs no
# reference file, and unlike `-newermt "@<epoch>"` it cannot be rejected by one
# implementation and honored by the other. `-quit` is NOT GNU-only - BSD find on
# macOS 15 accepts it, verified directly - so it is used when this find takes it and
# omitted when it does not, rather than dropped on an assumption. It is a pure
# short-circuit: with it the walk stops at the first recent file instead of listing
# a live session's whole tree.
QUIT_OK=no
probe_capability() {
  find "$ROOT" -maxdepth 0 -mmin "-$WINDOW_MINUTES" -print -quit >/dev/null 2>&1 && {
    QUIT_OK=yes
    return 0
  }
  find "$ROOT" -maxdepth 0 -mmin "-$WINDOW_MINUTES" -print >/dev/null 2>&1
}

# has_recent_file <dir>: the liveness probe, and the one owner of "is this session
# still alive". Runs only after probe_capability succeeded, so find is known to
# understand the question. The ANSWER IS THE EXIT STATUS, and there are three:
#   0  a file was modified inside the window - the session is alive
#   1  demonstrably no such file - the session is dead and the dir is reapable
#   2  the walk errored without finding one - a PARTIAL answer, not a verdict
# A caller must treat 2 like 0 unless the hard ceiling has passed. This function
# guards an `rm -rf`, so a doubtful check spares the tree; only a definite 1 may
# clear a deletion on its own.
# find's exit status must reach the verdict unmangled, so the output is captured
# straight rather than piped - inside a command substitution `${PIPESTATUS[0]}` would
# describe the assignment, not the pipeline, and silently read as success. Output
# beats status: a walk that printed a recent file answered the question, whatever it
# tripped over afterwards.
has_recent_file() {  # <dir>
  local d=$1 out rc=0
  if [ "$QUIT_OK" = yes ]; then
    out=$(find "$d" -type f -mmin "-$WINDOW_MINUTES" -print -quit 2>/dev/null) || rc=$?
  else
    out=$(find "$d" -type f -mmin "-$WINDOW_MINUTES" -print 2>/dev/null) || rc=$?
  fi
  [ -n "$out" ] && return 0
  [ "$rc" -eq 0 ] || return 2
  return 1
}

# past_hard_ceiling <dir>: is the session dir's OWN mtime older than the ceiling?
# -maxdepth 0 stats that one directory and descends into nothing, so no unreadable
# child can make this unanswerable - which is precisely why it is the backstop for a
# tree that cannot be walked. A false (or unanswerable) reading keeps sparing it.
past_hard_ceiling() {  # <dir>
  local d=$1 out rc=0
  out=$(find "$d" -maxdepth 0 -mmin "-$CEILING_MINUTES" -print 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ -z "$out" ]
}

is_protected() {  # <path>
  local p=$1 sub
  for sub in ${PROTECT[@]+"${PROTECT[@]}"}; do
    [ -n "$sub" ] || continue
    case "$p" in *"$sub"*) return 0 ;; esac
  done
  return 1
}

# THE CAPABILITY GATE, before a single directory is considered. A find that cannot
# evaluate the question returns the same empty output for a live session as for a
# dead one, which is exactly how this script once deleted live crews' scratch. It is
# a property of the tool, so it is decided once and it stops the whole run.
if ! probe_capability; then
  echo "SCRATCH_REAP: liveness probe unusable - this find cannot evaluate '-mmin -$WINDOW_MINUTES', so every session dir would read as dead; refusing to reap on an unknown answer (nothing deleted)"
  exit 0
fi

reaped=0
reaped_kb=0
partial=0
partial_dirs=""
# Session dirs are named as UUIDs (8-4-4-4-12) at depth 1 or 2 under the root, so
# the glob naturally skips non-session siblings like bundled-skills/<version>.
while IFS= read -r d; do
  [ -n "$d" ] || continue
  is_protected "$d" && continue
  # A single file modified inside the window means the session is still active.
  # Only a definite "dead", or the hard ceiling, falls through to a deletion.
  probe=0; has_recent_file "$d" || probe=$?
  case "$probe" in
    0) continue ;;
    2)
      # A partial answer: the walk errored before it could rule this session dead.
      # Spare it and NAME it - unless its own mtime is past the hard ceiling, where
      # sparing it forever is the larger mistake. See the header.
      if past_hard_ceiling "$d"; then
        echo "SCRATCH_REAP: $d could not be walked, and its own mtime is >$(( CEILING_MINUTES / 60 ))h old - reaping at the hard ceiling"
      else
        partial=$((partial + 1))
        partial_dirs="$partial_dirs $d"
        continue
      fi
      ;;
  esac
  kb=$(du -sk "$d" 2>/dev/null | cut -f1); kb=${kb:-0}
  if [ "$DRY_RUN" = 1 ]; then
    echo "SCRATCH_REAP: would reap $d (~${kb}K, untouched >${MAX_AGE_HOURS}h)"
  else
    rm -rf -- "$d" 2>/dev/null && echo "SCRATCH_REAP: reaped $d (~${kb}K)"
  fi
  reaped=$((reaped + 1))
  reaped_kb=$((reaped_kb + kb))
done < <(find "$ROOT" -mindepth 1 -maxdepth 2 -type d \
           -name '????????-????-????-????-????????????' 2>/dev/null)

# Best-effort: drop now-empty project-encoded parent dirs left behind.
[ "$DRY_RUN" = 1 ] || find "$ROOT" -mindepth 1 -maxdepth 1 -type d -empty -exec rmdir {} + 2>/dev/null || true

# Reclaim orphaned firstmate task temp directories (/tmp/fm-*) untouched for >24h.
# This prevents buildup of tasktmp folders left by tasks that crashed or were killed before teardown.
# HOST-WIDE ON PURPOSE, and it stays that way now that bin/fm-peer-lib.sh scopes each
# root to its owning home: the orphans this exists to reclaim are exactly the ones
# whose home may no longer exist, so mtime and not ownership is the safety property.
# Scoping the glob to this home would reclaim strictly less and reclaim nothing sooner.
# 24h untouched is far longer than any live task goes without writing its temp root.
if [ "$DRY_RUN" = 1 ]; then
  find /tmp -maxdepth 1 -type d -name "fm-*" -mmin +1440 -exec echo "SCRATCH_REAP: would reap {} (firstmate tmp)" \; 2>/dev/null || true
else
  find /tmp -maxdepth 1 -type d -name "fm-*" -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
fi

# A spared-on-doubt is never silent, and never a bare count: an operator who cannot
# see WHICH dir was spared, or why, has an unexplained alarm rather than a
# diagnosable one. On stdout, not stderr, because bin/fm-bootstrap.sh discards stderr.
if [ "$partial" -gt 0 ]; then
  echo "SCRATCH_REAP: spared $partial session scratch dir(s) whose tree could not be fully walked (an unreadable entry, or files changing under the walk); each is reaped anyway once its own mtime passes $(( CEILING_MINUTES / 60 ))h:$partial_dirs"
fi
if [ "$reaped" -gt 0 ]; then
  verb=$([ "$DRY_RUN" = 1 ] && echo "would reclaim" || echo "reclaimed")
  echo "SCRATCH_REAP: $verb $reaped session scratch dir(s), ~$((reaped_kb / 1024))M (untouched >${MAX_AGE_HOURS}h)"
elif [ "$VERBOSE" = 1 ]; then
  echo "SCRATCH_REAP: nothing to reap (no session scratch untouched >${MAX_AGE_HOURS}h)"
fi
exit 0
