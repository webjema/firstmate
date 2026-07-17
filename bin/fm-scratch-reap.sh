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
# NO file modified within the window is a dead session. Three hard rails on top:
#   1. The root must match the harness pattern (basename claude-<digits>), so the
#      reaper can never be pointed at an arbitrary directory.
#   2. A --protect <substr> (repeatable) skips any session dir whose path matches,
#      so a caller that knows a live crew's worktree can guarantee it is spared
#      regardless of age.
#   3. --dry-run prints what it WOULD reap and deletes nothing.
# The current session's own scratch is naturally spared: it is being written to
# now, so its newest mtime is inside the window. Pass --self <id> to spare it by
# name as well.
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

cutoff=$(( $(date +%s) - MAX_AGE_HOURS * 3600 ))

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
# Session dirs are named as UUIDs (8-4-4-4-12) at depth 1 or 2 under the root, so
# the glob naturally skips non-session siblings like bundled-skills/<version>.
while IFS= read -r d; do
  [ -n "$d" ] || continue
  is_protected "$d" && continue
  # A single file newer than the cutoff means the session is still active: spare it.
  if [ -n "$(find "$d" -type f -newermt "@$cutoff" -print -quit 2>/dev/null)" ]; then
    continue
  fi
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

if [ "$reaped" -gt 0 ]; then
  verb=$([ "$DRY_RUN" = 1 ] && echo "would reclaim" || echo "reclaimed")
  echo "SCRATCH_REAP: $verb $reaped session scratch dir(s), ~$((reaped_kb / 1024))M (untouched >${MAX_AGE_HOURS}h)"
elif [ "$VERBOSE" = 1 ]; then
  echo "SCRATCH_REAP: nothing to reap (no session scratch untouched >${MAX_AGE_HOURS}h)"
fi
exit 0
