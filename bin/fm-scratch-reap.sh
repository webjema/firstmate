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
#
# A SECOND PASS reclaims orphaned firstmate task temp roots (<FM_SCRATCH_TMP_ROOT>/fm-*,
# created by fm_task_tmp_root in bin/fm-peer-lib.sh) left by tasks that died before
# teardown. It runs rails 2-4 above - --protect and --self bind it, so a session
# cannot reap its own workspace - plus a fifth that is its alone: nothing is reaped
# while a running process has its cwd inside it, holds a file in it open, or is
# executing a binary from it. Its rationale is at the pass itself.
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
# Env for the second pass: FM_SCRATCH_TMP_ROOT (default /tmp) is the root it sweeps
# for fm-* task temp roots; FM_SCRATCH_PROC_ROOT (default /proc) is where the
# process rail looks.
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
has_recent_file() {  # <dir> [window-minutes]
  local d=$1 window=${2:-$WINDOW_MINUTES} out rc=0
  if [ "$QUIT_OK" = yes ]; then
    out=$(find "$d" -type f -mmin "-$window" -print -quit 2>/dev/null) || rc=$?
  else
    out=$(find "$d" -type f -mmin "-$window" -print 2>/dev/null) || rc=$?
  fi
  [ -n "$out" ] && return 0
  [ "$rc" -eq 0 ] || return 2
  return 1
}

# own_mtime_older_than <dir> <minutes>: is the directory's OWN mtime older than
# <minutes>? -maxdepth 0 stats that one directory and descends into nothing, so no
# unreadable child can make this unanswerable - which is precisely why it is the
# backstop for a tree that cannot be walked. A false (or unanswerable) reading keeps
# sparing it.
# THIS IS NOT A LIVENESS TEST and must never be used as one. A directory's mtime
# moves only when an entry inside it is created, renamed or unlinked - never when a
# file already inside it is appended to - so a worker that creates its files once and
# writes into them for days has a frozen mtime while it is in constant use. Liveness
# is has_recent_file plus holds_live_process; this answers only "has its entry list
# changed", which is why it is safe as a ceiling and lethal as a verdict.
own_mtime_older_than() {  # <dir> <minutes>
  local d=$1 minutes=$2 out rc=0
  out=$(find "$d" -maxdepth 0 -mmin "-$minutes" -print 2>/dev/null) || rc=$?
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

# THE PROCESS RAIL. mtime answers "was this written to"; /proc answers "is something
# holding this right now", and that is the one signal a task that has gone quiet
# cannot fake. Both are needed: a crewmate's GOTMPDIR is created once at spawn and
# then only written INTO, and a build inside it holds an open fd long before it
# creates or renames an entry.
PROC_ROOT="${FM_SCRATCH_PROC_ROOT:-/proc}"

# resolve_links <path...>: the one owner of turning /proc link names into targets.
# It goes through xargs rather than one readlink call because a box with tens of
# thousands of open fds would exceed the argument list; xargs chunks it instead.
# Entries belonging to other users' processes do not resolve and are simply absent -
# they cannot hold a task root, which fm_task_tmp_root creates under this user.
resolve_links() {  # <path...>
  printf '%s\n' "$@" | xargs -r -d '\n' readlink -- 2>/dev/null
}

# proc_probe_capability: can this box be asked what a process is holding at all?
# Established ONCE, against our own pid's cwd - a link guaranteed to exist and to be
# readable by us - and through resolve_links, the SAME pipeline the sweep uses, so
# the find-shaped hole cannot reopen here: `xargs -d` is GNU-only, and a busybox
# xargs that rejected it would otherwise hand back an empty held-path list that reads
# as "nothing is alive". Same tool-property split as probe_capability, and the same
# consequence: a rail that cannot answer stops its pass rather than waving it through.
proc_probe_capability() {
  local own
  [ -d "$PROC_ROOT" ] || return 1
  own=$(resolve_links "$PROC_ROOT/$$/cwd") || return 1
  [ -n "$own" ]
}

# proc_held_paths: every path a running process is sitting in, holding open, or
# executing, one per line. Resolved for the whole run at once, not once per
# candidate: the answer does not vary by directory, and a fork per open fd on a busy
# box would cost more than the sweep reclaims. `exe` is in the glob because a process
# running a binary from inside a directory holds it without holding any fd there.
proc_held_paths() {
  resolve_links "$PROC_ROOT"/[0-9]*/cwd "$PROC_ROOT"/[0-9]*/exe "$PROC_ROOT"/[0-9]*/fd/*
}

# holds_live_process <dir> <held-paths>: does any held path resolve inside <dir>?
# <dir> must be canonical, because readlink returns the kernel's resolved target and
# a prefix test between two spellings of one path answers "no".
# A path readlink reported as "<target> (deleted)" still matches, which is the safe
# direction.
holds_live_process() {  # <dir> <held-paths>
  local d=$1 held=$2 p
  [ -n "$held" ] || return 1
  while IFS= read -r p; do
    case "$p" in "$d"|"$d"/*) return 0 ;; esac
  done <<< "$held"
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
# NUL-delimited, not line-delimited: a directory name may legally contain a newline,
# and the second line of one would be read as a separate, RELATIVE path - resolved
# against the caller's cwd, where every rail would then evaluate the wrong directory
# and clear it for deletion.
while IFS= read -r -d '' d; do
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
      if own_mtime_older_than "$d" "$CEILING_MINUTES"; then
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
           -name '????????-????-????-????-????????????' -print0 2>/dev/null)

# Best-effort: drop now-empty project-encoded parent dirs left behind.
[ "$DRY_RUN" = 1 ] || find "$ROOT" -mindepth 1 -maxdepth 1 -type d -empty -exec rmdir {} + 2>/dev/null || true

# Reclaim orphaned firstmate task temp roots (fm_task_tmp_root, bin/fm-peer-lib.sh),
# left by tasks that crashed or were killed before teardown.
# HOST-WIDE ON PURPOSE, and it stays that way now that bin/fm-peer-lib.sh scopes each
# root to its owning home: the orphans this exists to reclaim are exactly the ones
# whose home may no longer exist, so age and not ownership is the safety property.
# Scoping the glob to this home would reclaim strictly less and reclaim nothing sooner.
#
# It runs the SAME rails as the session-dir pass, because it is the same question.
# It used to run none of them - `find /tmp -type d -name 'fm-*' -mmin +1440 -exec
# rm -rf {} +` and nothing else - on the premise that "24h untouched is far longer
# than any live task goes without writing its temp root". That premise is false, and
# the directory mtime it rests on is the reason: writing INTO a directory is exactly
# what a directory mtime does not record (see own_mtime_older_than). A task root is
# created once at spawn and its entry list never changes again, so a task of any
# length read as abandoned. On 2026-08-24 the same rule at a 60-minute threshold, in
# this box's system-wide cleaner, deleted a live agent's GOTMPDIR mid-task and
# reported success; a longer window changes how often that happens, not whether it
# can. So the dir's own mtime is kept as a NECESSARY condition and is no longer a
# sufficient one: a live process holding the root, or any file inside it written
# within the window, spares it.
# Canonical, because the process rail prefix-matches candidates against the kernel's
# own resolved paths, and /tmp is a symlink on more than one platform. A root that
# cannot be resolved is used as given rather than dropped.
TMP_SWEEP_ROOT="${FM_SCRATCH_TMP_ROOT:-/tmp}"
TMP_SWEEP_ROOT=$(readlink -f -- "$TMP_SWEEP_ROOT" 2>/dev/null) ||
  TMP_SWEEP_ROOT="${FM_SCRATCH_TMP_ROOT:-/tmp}"
TMP_WINDOW_MINUTES=1440
TMP_CEILING_MINUTES=$(( TMP_WINDOW_MINUTES * HARD_CEILING_MULTIPLE ))

# NUL-delimited for the reason spelled out at the session-dir loop above, and it is
# not theoretical here: this sweep is host-wide by design and /tmp is world-writable,
# so any local process can create a `fm-x<newline>relative/path` entry in it.
TMP_CANDIDATES=()
while IFS= read -r -d '' d; do
  [ -n "$d" ] && TMP_CANDIDATES+=("$d")
done < <(find "$TMP_SWEEP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'fm-*' -print0 2>/dev/null)

tmp_reaped=0
tmp_reaped_kb=0
tmp_partial=0
tmp_partial_dirs=""
if [ "${#TMP_CANDIDATES[@]}" -eq 0 ]; then
  :
elif ! proc_probe_capability; then
  # Fail closed, and only where it costs something: a box with no readable /proc
  # cannot be asked whether a task is still using its temp root, and a directory
  # mtime alone is the defect above. Said once, and only when there was something to
  # decide, so a clean box stays silent.
  echo "SCRATCH_REAP: cannot read $PROC_ROOT, so 'is a live task using this' is unanswerable here; leaving ${#TMP_CANDIDATES[@]} $TMP_SWEEP_ROOT/fm-* dir(s) alone (nothing deleted)"
else
  held=$(proc_held_paths)
  for d in ${TMP_CANDIDATES[@]+"${TMP_CANDIDATES[@]}"}; do
    is_protected "$d" && continue
    holds_live_process "$d" "$held" && continue
    own_mtime_older_than "$d" "$TMP_WINDOW_MINUTES" || continue
    probe=0; has_recent_file "$d" "$TMP_WINDOW_MINUTES" || probe=$?
    case "$probe" in
      0) continue ;;
      2)
        if own_mtime_older_than "$d" "$TMP_CEILING_MINUTES"; then
          echo "SCRATCH_REAP: $d could not be walked, and its own mtime is >$(( TMP_CEILING_MINUTES / 60 ))h old - reaping at the hard ceiling"
        else
          tmp_partial=$((tmp_partial + 1))
          tmp_partial_dirs="$tmp_partial_dirs $d"
          continue
        fi
        ;;
    esac
    kb=$(du -sk "$d" 2>/dev/null | cut -f1); kb=${kb:-0}
    if [ "$DRY_RUN" = 1 ]; then
      echo "SCRATCH_REAP: would reap $d (~${kb}K, firstmate task temp, unused >$(( TMP_WINDOW_MINUTES / 60 ))h)"
    else
      rm -rf -- "$d" 2>/dev/null && echo "SCRATCH_REAP: reaped $d (~${kb}K, firstmate task temp)"
    fi
    tmp_reaped=$((tmp_reaped + 1))
    tmp_reaped_kb=$((tmp_reaped_kb + kb))
  done
fi
if [ "$tmp_partial" -gt 0 ]; then
  echo "SCRATCH_REAP: spared $tmp_partial firstmate task temp root(s) whose tree could not be fully walked; each is reaped anyway once its own mtime passes $(( TMP_CEILING_MINUTES / 60 ))h:$tmp_partial_dirs"
fi
if [ "$tmp_reaped" -gt 0 ]; then
  tmp_verb=$([ "$DRY_RUN" = 1 ] && echo "would reclaim" || echo "reclaimed")
  echo "SCRATCH_REAP: $tmp_verb $tmp_reaped firstmate task temp root(s), ~$((tmp_reaped_kb / 1024))M (unused >$(( TMP_WINDOW_MINUTES / 60 ))h)"
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
