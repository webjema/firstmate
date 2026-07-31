#!/usr/bin/env bash
# fm-disk-guard.sh — reclaim disk when the box is running out, not when a session happens to start.
#
# WHY THIS EXISTS. firstmate already had two janitors, and on 2026-07-31 this box
# still hit 94% full (9.4G free of 154G) with 55G of reclaimable garbage on it.
# Neither janitor was broken; both were aimed somewhere else. See
# docs/incidents/disk-exhaustion-2026-07-31.md for the measured breakdown.
#   fm-scratch-reap.sh runs from fm-bootstrap.sh, i.e. at SESSION START. A session
#     that stays up for days never runs it again, and /tmp grew to 27G underneath
#     one that did exactly that.
#   treehouse prune --global --yes runs from the same place, and is "safe by
#     default": it skips a worktree that is leased, dirty, or whose HEAD is not an
#     ancestor of the default branch. Sixteen finished worktrees (32G) were skipped
#     on BOTH counts - their crews died without returning the lease, and their PRs
#     were SQUASH-merged, which lands the work but leaves HEAD off master's
#     ancestry forever. Prune is right to skip those; it just means prune alone
#     never reclaims them.
#   Nothing at all owned npm caches, jest/node/v8 compile caches, or Playwright
#     bundles - 8G here.
# So the gap is not "a janitor is missing", it is that every janitor fires on a
# LIFECYCLE EVENT and none of them fires on the condition that actually matters:
# the disk being nearly full. This script is the missing trigger, plus the sweeps
# that had no owner.
#
# WHAT IT WILL NOT DO. It never overrides a treehouse lease. A lease is a crew's
# claim on its worktree, and a crew that is merely wedged looks exactly like a crew
# that is dead; taking its worktree would destroy unlanded work to save disk, which
# is the wrong trade at any occupancy. Leased-and-landed worktrees are the single
# largest reclaimable class on a busy box, so they are MEASURED AND REPORTED with
# the exact command to release them, and left on disk for the first mate to raise.
# Reporting is not a consolation prize here: on the day this script was written it
# was the whole 32G.
#
# TIERS. Two thresholds, each expressed twice - as an absolute free-space floor and
# as a used-percentage - because neither alone survives both box sizes. A 4T disk at
# 92% still has 320G free and needs no janitor; a 50G disk at 80% has 10G free and
# does. Whichever reads worse picks the tier.
#   warn      cheap, idempotent sweeps of things that are certainly garbage.
#   critical  the warn set with tighter age windows, plus caches whose only cost of
#             loss is rebuild time, plus the unleased-and-landed worktree sweep.
#
# SAFETY MODEL, inherited from fm-scratch-reap.sh and extended.
#   1. ALLOWLIST, NEVER PATTERN. Every path this script deletes is either built from
#      a fixed name in one of the tables below, or handed to a tool whose own safety
#      model owns the decision (treehouse, fm-scratch-reap.sh). There is no
#      caller-supplied path and no glob that could widen to a home directory.
#   2. FAIL CLOSED. df unparseable, jq missing, lease state unreadable, gh
#      unauthenticated - every one of these SPARES the target and says so. A janitor
#      that guesses is worse than one that does nothing, because the thing it
#      guesses about is deletion.
#   3. --dry-run prints every action and takes none.
#   4. Never a gate. Always exits 0 except on bad arguments, so no caller can be
#      blocked by the janitor.
#
# Usage: fm-disk-guard.sh [options]
#   --path DIR             filesystem to measure (default /tmp; env FM_DISK_PATH).
#                          Only the MEASUREMENT follows this; the sweeps always act
#                          on their own allowlisted roots.
#   --tier TIER            force ok|warn|critical instead of measuring (testing)
#   --dry-run              print actions, delete nothing (env FM_DISK_DRY_RUN=1)
#   --verbose              print the tier decision even when no action is taken
#   --report-only          measure and report; never delete anything
#   -h|--help              this header
#
# Thresholds (env):
#   FM_DISK_WARN_FREE_GB       default 20    free space at or below which warn fires
#   FM_DISK_CRITICAL_FREE_GB   default 8     ... and critical
#   FM_DISK_WARN_USED_PCT      default 85    used percentage at or above which warn fires
#   FM_DISK_CRITICAL_USED_PCT  default 92    ... and critical
#   FM_DISK_CACHES             default "npm tmpbuild playwright"
#                              which cache families critical may clear; empty disables all
#   FM_TREEHOUSE_ROOT          default ~/.treehouse
#
# Prints one "DISK_GUARD: ..." line per action plus a summary. Silent when the disk
# is healthy unless --verbose.
set -u

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
}

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MEASURE_PATH="${FM_DISK_PATH:-/tmp}"
WARN_FREE_GB="${FM_DISK_WARN_FREE_GB:-20}"
CRIT_FREE_GB="${FM_DISK_CRITICAL_FREE_GB:-8}"
WARN_USED_PCT="${FM_DISK_WARN_USED_PCT:-85}"
CRIT_USED_PCT="${FM_DISK_CRITICAL_USED_PCT:-92}"
CACHES="${FM_DISK_CACHES-npm tmpbuild playwright}"
TREEHOUSE_ROOT="${FM_TREEHOUSE_ROOT:-$HOME/.treehouse}"
DRY_RUN="${FM_DISK_DRY_RUN:-0}"
VERBOSE=0
REPORT_ONLY=0
FORCED_TIER=

die() { echo "fm-disk-guard: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --path) MEASURE_PATH="${2:?--path needs a dir}"; shift 2 ;;
    --tier) FORCED_TIER="${2:?--tier needs ok|warn|critical}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --report-only) REPORT_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

case "$FORCED_TIER" in
  ''|ok|warn|critical) ;;
  *) die "--tier must be ok, warn, or critical, got '$FORCED_TIER'" ;;
esac
for v in WARN_FREE_GB CRIT_FREE_GB WARN_USED_PCT CRIT_USED_PCT; do
  case "${!v}" in
    ''|*[!0-9]*) die "$v must be a non-negative integer, got '${!v}'" ;;
  esac
done

say() { echo "DISK_GUARD: $*"; }

# free_kb / used_pct: POSIX `df -Pk`, which pins the output to one line per
# filesystem with 1024-byte blocks on BOTH GNU and BSD. Plain `df -h` is not
# parseable across the two (differing columns, and GNU wraps a long device name
# onto its own line); -P is the flag that makes the columns a contract.
# Sets FREE_KB and USED_PCT. Returns non-zero if the answer is not a pair of
# integers, which is a FAIL-CLOSED signal: an unmeasurable disk takes no action.
FREE_KB=0
USED_PCT=0
measure() {  # <path>
  local line
  line=$(df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4, $5}') || return 1
  FREE_KB=$(echo "$line" | awk '{print $1}')
  USED_PCT=$(echo "$line" | awk '{gsub(/%/,"",$2); print $2}')
  case "$FREE_KB" in ''|*[!0-9]*) return 1 ;; esac
  case "$USED_PCT" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

gb() { echo $(( $1 / 1024 / 1024 )); }

# Whether a named cache family is allowed to be cleared. FM_DISK_CACHES is a
# whitespace-separated allowlist so a fleet can disable one family (say, Playwright
# on a box where re-downloading browsers is expensive) without disabling the guard.
cache_allowed() {  # <family>
  local want=$1 f
  for f in $CACHES; do [ "$f" = "$want" ] && return 0; done
  return 1
}

RECLAIMED_KB=0
ACTIONS=0

# reclaim: delete one allowlisted directory's contents and count what it freed.
# Takes the path plus a human reason. Every caller passes a path built from a fixed
# name in this file - never from argv, never from a glob that could widen past its
# intended parent - because this function is the one place that deletes.
reclaim() {  # <dir> <reason>
  local d=$1 reason=$2 kb
  [ -d "$d" ] || return 0
  kb=$(du -sk "$d" 2>/dev/null | cut -f1); kb=${kb:-0}
  [ "$kb" -gt 0 ] || return 0
  if [ "$DRY_RUN" = 1 ] || [ "$REPORT_ONLY" = 1 ]; then
    say "would reclaim $d (~$(( kb / 1024 ))M, $reason)"
  else
    rm -rf -- "$d" 2>/dev/null || true
    say "reclaimed $d (~$(( kb / 1024 ))M, $reason)"
  fi
  RECLAIMED_KB=$(( RECLAIMED_KB + kb ))
  ACTIONS=$(( ACTIONS + 1 ))
}

# ---------------------------------------------------------------------------
# Sweep 1: harness scratch. Delegates to the existing reaper rather than
# reimplementing its liveness probe - that probe is the piece that once deleted
# live sessions, and it must keep exactly one owner. All this adds is a tighter age
# window as pressure rises: 48h is right for a routine session-start sweep, far too
# patient for a disk with hours of life left.
# ---------------------------------------------------------------------------
#
# THE TIGHTER WINDOW NEEDS A SECOND LIVENESS SIGNAL, and this is not a refinement -
# without it the tightening is a bug. The reaper's proxy for "alive" is "some file
# was modified inside the window", which is sound at 48h and false at 6h: a live
# session that is merely IDLE - a crew parked waiting on review, or a running
# database with no writes - touches nothing for hours and reads as dead. Verified
# on 2026-07-31: at --max-age-hours 6 the reaper offered up a session scratch dir
# that had a Postgres serving out of it, started the previous day.
# So before shortening the window, ask the operating system which sessions are
# actually alive and hand those to the reaper as --protect. mtime answers "was this
# written to recently"; a running process answers "is anyone still here", and only
# the second one is the question. If the probe cannot run, the window is NOT
# shortened - the guard falls back to the reaper's own safe default rather than
# reaping on a signal it could not gather.
live_session_ids() {
  # `ps -eo args=` is the portable spelling: BSD and GNU ps both accept it, unlike
  # /proc, which does not exist on macOS. Any process whose command line mentions a
  # session scratch path is that session voting for itself.
  # shellcheck disable=SC2009  # pgrep matches processes; this needs to EXTRACT the session id from each command line, which pgrep cannot do portably (-a is not on BSD pgrep).
  ps -eo args= 2>/dev/null |
    grep -oE '/tmp/claude-[0-9]+/[^ ]*' |
    grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' |
    sort -u
}

sweep_scratch() {  # <max-age-hours>
  local hours=$1 id protects=() ids
  [ -x "$FM_ROOT/bin/fm-scratch-reap.sh" ] || return 0
  ids=$(live_session_ids) || ids=
  if [ -z "$ids" ]; then
    # No answer is not the same as "nothing is alive": this box always has at least
    # the caller's own session running, so an empty list means the probe failed.
    # Fall back to the reaper's default window instead of reaping on a blind guess.
    say "cannot enumerate live sessions; leaving the scratch window at the reaper default"
    hours=48
  else
    while IFS= read -r id; do
      [ -n "$id" ] && protects+=(--protect "$id")
    done <<< "$ids"
  fi
  local args=(--max-age-hours "$hours" ${protects[@]+"${protects[@]}"})
  { [ "$DRY_RUN" = 1 ] || [ "$REPORT_ONLY" = 1 ]; } && args+=(--dry-run)
  say "sweeping harness scratch (untouched >${hours}h, sparing $(echo "$ids" | grep -c . ) live session(s))"
  "$FM_ROOT/bin/fm-scratch-reap.sh" "${args[@]}" 2>/dev/null || true
  ACTIONS=$(( ACTIONS + 1 ))
}

# ---------------------------------------------------------------------------
# Sweep 2: build and test caches with no owner. Fixed names only - a glob like
# /tmp/*cache* would eventually match something that is not a cache.
#
# The age window is the whole safety story here. These roots are written by live
# processes, so under a naive mtime gate a busy box never reclaims them; but they
# are PURE caches, and the cost of deleting a warm one is a recompile, not data. So
# warn is patient (24h, "nothing has touched this in a day, it is dead") and
# critical is not (1h, "the disk matters more than your compile cache").
# ---------------------------------------------------------------------------
TMP_BUILD_CACHES="jest_rt node-compile-cache metro-cache"
sweep_tmp_build() {  # <min-age-minutes>
  local mins=$1 name d
  cache_allowed tmpbuild || return 0
  for name in $TMP_BUILD_CACHES; do
    d="/tmp/$name"
    [ -d "$d" ] || continue
    # -maxdepth 0 stats the root itself; an empty result means it is younger than
    # the window, so it stays. Output, not exit status, is the answer here.
    [ -n "$(find "$d" -maxdepth 0 -mmin "+$mins" 2>/dev/null)" ] || continue
    reclaim "$d" "build cache, untouched >$(( mins / 60 ))h"
  done
  # v8-compile-cache-<uid>: same family, but the uid suffix means it cannot be a
  # fixed string. The prefix is still fixed and -maxdepth 1 keeps it inside /tmp.
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    reclaim "$d" "v8 compile cache, untouched >$(( mins / 60 ))h"
  done < <(find /tmp -maxdepth 1 -type d -name 'v8-compile-cache-*' -mmin "+$mins" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Sweep 3: package-manager and browser caches. Critical tier only: these cost real
# time to rebuild (an npm cache refills over many installs, a Playwright bundle is a
# multi-hundred-MB download), so they are the last thing traded away, not the first.
# Only the _cacache payload is removed, never the cache directory's config.
# ---------------------------------------------------------------------------
sweep_npm_caches() {
  local d
  cache_allowed npm || return 0
  for d in "$HOME"/.npm/_cacache "$HOME"/.npm-cache-*/_cacache; do
    [ -d "$d" ] || continue
    reclaim "$d" "npm cache, refills on next install"
  done
}

sweep_playwright() {
  local d
  cache_allowed playwright || return 0
  for d in "$HOME/.cache/ms-playwright" "$HOME/Library/Caches/ms-playwright"; do
    [ -d "$d" ] || continue
    reclaim "$d" "playwright browsers, restore with 'npx playwright install'"
  done
}

# ---------------------------------------------------------------------------
# Sweep 4: treehouse worktrees.
#
# Two passes with very different rights, and the line between them is the lease.
#
# PASS A delegates to `treehouse prune --global --yes`, whose safety model is the
# authority on what is disposable. It skips anything leased, dirty, in use, or whose
# HEAD is not an ancestor of the default branch.
#
# PASS B exists because that last condition makes prune blind to the most common
# finished worktree on a squash-merge repo. GitHub's "Squash and merge" replays the
# branch as ONE NEW COMMIT on master; the branch's own commits are never in master's
# history, so `merge-base --is-ancestor` says "unmerged" forever even though the work
# shipped. On 2026-07-31 that described all sixteen stale worktrees on this box.
# So pass B asks the question prune cannot: is there a MERGED PR for this branch?
# It is deliberately three independent checks, and a worktree must pass every one:
#   landed    gh reports a merged PR for the branch
#   pushed    no commits exist locally that the remote does not have
#   clean     no uncommitted changes except lockfile churn from a warm install
# Any check that cannot be answered - gh missing, no upstream, jq absent, lease state
# unreadable - is a FAILURE, not a pass. The default is always to keep the worktree.
#
# And pass B still never touches a leased worktree. Those are counted and reported
# with the command that would release them, for the first mate to raise with the
# user, because a lease is a crew's claim and only its owner may drop it.
# ---------------------------------------------------------------------------
LEASED_LANDED=0
LEASED_LANDED_KB=0
LEASED_LANDED_PATHS=""

# lease_is_free <pool-state-json> <worktree-path>: true only when the state file
# says, unambiguously, that nothing holds this worktree. Anything else - the file
# missing, jq missing, the entry absent, a live owner_pid - reads as HELD.
lease_is_free() {  # <state-json> <path>
  local state=$1 path=$2 leased owner
  [ -f "$state" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  leased=$(jq -r --arg p "$path" '.worktrees[]? | select(.path==$p) | (.leased // false) | tostring' "$state" 2>/dev/null) || return 1
  [ "$leased" = "false" ] || return 1
  owner=$(jq -r --arg p "$path" '.worktrees[]? | select(.path==$p) | (.owner_pid // empty) | tostring' "$state" 2>/dev/null) || return 1
  # An owner pid that is still running holds the slot even without a lease flag.
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then return 1; fi
  return 0
}

# wt_is_landed <dir>: the three-check audit above. Silent; the answer is the status.
wt_is_landed() {  # <repo-dir>
  local d=$1 branch dirty unpushed pr
  branch=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] && [ "$branch" != "HEAD" ] || return 1
  # pushed: an unset upstream means the question is unanswerable, so it fails.
  unpushed=$(git -C "$d" log --oneline '@{u}..HEAD' 2>/dev/null) || return 1
  [ -z "$unpushed" ] || return 1
  # clean, allowing only the lockfile churn a warm `npm install` leaves behind.
  dirty=$(git -C "$d" status --porcelain 2>/dev/null | grep -vE '(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml)$') || true
  [ -z "$dirty" ] || return 1
  # landed: a merged PR for this exact branch. gh resolves the repo from the
  # WORKING DIRECTORY, so this must run inside the worktree - called from anywhere
  # else it would silently answer about whatever repo the caller happened to be in,
  # and a "merged" from the wrong repo is exactly the wrong way to be wrong here.
  command -v gh >/dev/null 2>&1 || return 1
  pr=$(cd "$d" && gh pr list --head "$branch" --state merged --json number --jq 'length' 2>/dev/null) || return 1
  case "$pr" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pr" -gt 0 ] || return 1
  return 0
}

sweep_treehouse() {  # <allow-destroy 0|1>
  local allow_destroy=$1 pool state slot repo kb

  # Pass A: treehouse's own definition of disposable.
  if command -v treehouse >/dev/null 2>&1; then
    if [ "$DRY_RUN" = 1 ] || [ "$REPORT_ONLY" = 1 ]; then
      say "would run 'treehouse prune --global --yes'"
    else
      say "pruning disposable treehouse worktrees"
      treehouse prune --global --yes >/dev/null 2>&1 || true
    fi
    ACTIONS=$(( ACTIONS + 1 ))
  fi
  [ -d "$TREEHOUSE_ROOT" ] || return 0

  # Pass B: landed-but-invisible-to-prune. Walk pool/slot/repo.
  for pool in "$TREEHOUSE_ROOT"/*/; do
    [ -d "$pool" ] || continue
    state="$pool/treehouse-state.json"
    for slot in "$pool"*/; do
      [ -d "$slot" ] || continue
      for repo in "$slot"*/; do
        [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || continue
        repo=${repo%/}
        wt_is_landed "$repo" || continue
        kb=$(du -sk "$repo" 2>/dev/null | cut -f1); kb=${kb:-0}
        if lease_is_free "$state" "$repo"; then
          if [ "$allow_destroy" = 1 ] && [ "$DRY_RUN" != 1 ] && [ "$REPORT_ONLY" != 1 ]; then
            # --include-unlanded is required because treehouse reads a squash-merged
            # branch as unmerged (see the header); the merged-PR check above is what
            # actually established that the work landed. --include-leased and
            # --include-in-use are deliberately NOT passed, so treehouse's own
            # lease and running-process rails still get the last word.
            treehouse destroy "$repo" --yes --include-unlanded >/dev/null 2>&1 || true
            # Report what HAPPENED, not what was attempted: treehouse can still
            # decline (a process inside the worktree, an unresolvable repo), and a
            # janitor that reports phantom reclamations teaches the operator to
            # distrust the only number it produces.
            if [ -d "$repo" ]; then
              say "could not destroy landed unleased worktree $repo (treehouse declined; it stays)"
              ACTIONS=$(( ACTIONS + 1 ))
              continue
            fi
            say "destroyed landed unleased worktree $repo (~$(( kb / 1024 ))M)"
          else
            say "would destroy landed unleased worktree $repo (~$(( kb / 1024 ))M)"
          fi
          RECLAIMED_KB=$(( RECLAIMED_KB + kb ))
          ACTIONS=$(( ACTIONS + 1 ))
        else
          # Held by a crew. Measured, named, never touched.
          LEASED_LANDED=$(( LEASED_LANDED + 1 ))
          LEASED_LANDED_KB=$(( LEASED_LANDED_KB + kb ))
          LEASED_LANDED_PATHS="$LEASED_LANDED_PATHS $repo"
        fi
      done
    done
  done
}

# ---------------------------------------------------------------------------
# Decide the tier and act.
# ---------------------------------------------------------------------------
if [ -n "$FORCED_TIER" ]; then
  TIER=$FORCED_TIER
  say "tier forced to $TIER"
elif ! measure "$MEASURE_PATH"; then
  # Rail 2. An unreadable df is exactly the shape of failure that makes a janitor
  # dangerous: every threshold comparison against a garbage number is arbitrary.
  say "cannot measure free space on '$MEASURE_PATH' (df -Pk gave no usable answer); taking no action"
  exit 0
else
  FREE_GB=$(gb "$FREE_KB")
  TIER=ok
  if [ "$FREE_GB" -le "$CRIT_FREE_GB" ] || [ "$USED_PCT" -ge "$CRIT_USED_PCT" ]; then
    TIER=critical
  elif [ "$FREE_GB" -le "$WARN_FREE_GB" ] || [ "$USED_PCT" -ge "$WARN_USED_PCT" ]; then
    TIER=warn
  fi
  if [ "$TIER" = ok ]; then
    [ "$VERBOSE" = 1 ] && say "ok - ${FREE_GB}G free (${USED_PCT}% used) on $MEASURE_PATH"
    exit 0
  fi
  say "$TIER - ${FREE_GB}G free (${USED_PCT}% used) on $MEASURE_PATH"
fi

case "$TIER" in
  warn)
    sweep_scratch 12
    sweep_tmp_build 1440
    sweep_treehouse 0
    ;;
  critical)
    sweep_scratch 6
    sweep_tmp_build 60
    sweep_npm_caches
    sweep_playwright
    sweep_treehouse 1
    ;;
esac

if [ "$LEASED_LANDED" -gt 0 ]; then
  # The escalation path. This is not a warning about a risk - it is a measured
  # amount of disk that firstmate is deliberately declining to take, and the only
  # actor who may release it is the user. Give them the number and the command.
  say "$LEASED_LANDED landed worktree(s) holding ~$(( LEASED_LANDED_KB / 1024 ))M are LEASED and were not touched."
  # shellcheck disable=SC2086  # deliberate word-split: LEASED_LANDED_PATHS is a space-separated path list built above.
  say "a lease is a crew's claim; release them yourself with:$(printf ' treehouse destroy %s --yes --include-leased --include-unlanded;' $LEASED_LANDED_PATHS)"
fi

if measure "$MEASURE_PATH"; then
  say "done - $ACTIONS action(s), ~$(( RECLAIMED_KB / 1024 ))M identified, now $(gb "$FREE_KB")G free (${USED_PCT}% used)"
else
  say "done - $ACTIONS action(s), ~$(( RECLAIMED_KB / 1024 ))M identified"
fi
exit 0
