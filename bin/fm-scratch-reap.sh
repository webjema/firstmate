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
#      dead, and unknown, and unknown spares the tree. See has_recent_file below.
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
# Usage: fm-scratch-reap.sh [options]
#   --root DIR             scratch root (default: /tmp/claude-<uid>;
#                          env FM_SCRATCH_ROOT). Must be named claude-<digits>.
#   --max-age-hours N      reap a session dir untouched for more than N hours
#                          (default 48; env FM_SCRATCH_MAX_AGE_HOURS)
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

case "$MAX_AGE_HOURS" in
  ''|*[!0-9]*) die "--max-age-hours must be a non-negative integer, got '$MAX_AGE_HOURS'" ;;
esac

# Rail 1: only ever operate on a harness scratch root (basename claude-<digits>).
case "$(basename -- "$ROOT")" in
  claude-[0-9]*) ;;
  *) die "refusing: root '$ROOT' is not a claude-<uid> scratch root" ;;
esac
[ -d "$ROOT" ] || { [ "$VERBOSE" = 1 ] && echo "SCRATCH_REAP: root $ROOT absent, nothing to do"; exit 0; }

WINDOW_MINUTES=$(( MAX_AGE_HOURS * 60 ))

# has_recent_file <dir>: the liveness probe, and the one owner of "is this session
# still alive". The ANSWER IS THE EXIT STATUS, and there are three of them:
#   0  a file was modified inside the window - the session is alive
#   1  demonstrably no such file - the session is dead and the dir is reapable
#   2  the probe could not run - the answer is UNKNOWN
# A caller must treat 2 exactly like 0. This function guards an `rm -rf`, so an
# unanswerable check has to spare the tree; only a definite 1 may clear a deletion.
# `-mmin` is the portable primary here: BSD and GNU find both accept it, it needs no
# reference file, and unlike `-newermt "@<epoch>"` it cannot be rejected by one
# implementation and honored by the other. `-quit` is GNU-only and stays out for the
# same reason, so the walk is no longer short-circuited at the first match; the whole
# tree is traversed either way, and only a live dir now prints more than nothing.
# find's exit status must reach the verdict unmangled, so the output is captured
# straight rather than piped - inside a command substitution `${PIPESTATUS[0]}` would
# describe the assignment, not the pipeline, and silently read as success.
# Any non-zero find status, including a permission error part-way down the tree, is
# unknown rather than dead; sparing a reapable dir costs a little disk, and the other
# mistake costs a live crew its work.
has_recent_file() {  # <dir>
  local d=$1 out rc=0
  out=$(find "$d" -type f -mmin "-$WINDOW_MINUTES" -print 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$out" ] && return 0
  return 1
}

is_protected() {  # <path>
  local p=$1 sub
  for sub in ${PROTECT[@]+"${PROTECT[@]}"}; do
    [ -n "$sub" ] || continue
    case "$p" in *"$sub"*) return 0 ;; esac
  done
  return 1
}

reaped=0
reaped_kb=0
unknown=0
# Session dirs are named as UUIDs (8-4-4-4-12) at depth 1 or 2 under the root, so
# the glob naturally skips non-session siblings like bundled-skills/<version>.
while IFS= read -r d; do
  [ -n "$d" ] || continue
  is_protected "$d" && continue
  # A single file modified inside the window means the session is still active, and
  # an unanswerable probe is treated the same way. Only a definite "dead" falls through.
  probe=0; has_recent_file "$d" || probe=$?
  case "$probe" in
    0) continue ;;
    2) unknown=$((unknown + 1)); continue ;;
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

# A spared-on-unknown is never silent: a probe that cannot run means the reaper has
# stopped doing its job, and the whole point of rail 4 is that it says so instead of
# guessing. On stdout, not stderr, because bin/fm-bootstrap.sh discards stderr.
if [ "$unknown" -gt 0 ]; then
  echo "SCRATCH_REAP: spared $unknown session scratch dir(s) - liveness probe failed, refusing to reap on an unknown answer"
fi
if [ "$reaped" -gt 0 ]; then
  verb=$([ "$DRY_RUN" = 1 ] && echo "would reclaim" || echo "reclaimed")
  echo "SCRATCH_REAP: $verb $reaped session scratch dir(s), ~$((reaped_kb / 1024))M (untouched >${MAX_AGE_HOURS}h)"
elif [ "$VERBOSE" = 1 ]; then
  echo "SCRATCH_REAP: nothing to reap (no session scratch untouched >${MAX_AGE_HOURS}h)"
fi
exit 0
