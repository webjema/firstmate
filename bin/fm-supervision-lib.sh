# shellcheck shell=bash
# Shared DESCRIPTIVE supervision status: in-flight count, beacon age, and queue
# state - the numbers a banner prints, NOT a liveness verdict.
# Usage: . bin/fm-supervision-lib.sh
#
# The ONE authoritative answer to "is a live watcher supervising THIS home?" is
# bin/fm-wake-lib.sh's fm_watcher_healthy (home-lock OWNERSHIP), which
# bin/fm-guard.sh, bin/fm-turnend-guard.sh, and bin/fm-supervision-live.sh all
# call, so they cannot disagree. Beacon freshness is deliberately NOT that answer:
# an orphaned watcher keeps state/.last-watcher-beat warm while holding no lock,
# so FM_SUP_WATCHER_FRESH below is a descriptive age band for banner text only -
# never a supervision-live decision. This file populates FM_SUP_IN_FLIGHT,
# FM_SUP_SUPERVISABLE, and FM_SUP_BEACON_DESC for those banners.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta - EVERY recorded task. Human-facing
#                         context only ("N task(s) in flight"); NOT the gate for
#                         whether this home still needs a live watcher.
#   FM_SUP_SUPERVISABLE   count of metas that DEMAND a live watcher = every meta
#                         that is NOT detached. A detached task (`detached=` line,
#                         stamped by bin/fm-detach.sh) is one the user drives
#                         end to end; firstmate does zero watcher supervision or CI
#                         polling on it, so it must not force a watcher to stay
#                         armed. A released task (`released=`, bin/fm-teardown.sh's
#                         release-at-PR-open) STILL counts: the watcher is exactly
#                         what polls its PR's CI, so dropping it would silently kill
#                         post-PR supervision. The guards gate blind-turn blocking
#                         on THIS count, not FM_SUP_IN_FLIGHT.
#   FM_SUP_WATCHER_FRESH  true/false - DESCRIPTIVE: beacon within the grace window.
#                         NOT a liveness verdict (see the header); use
#                         fm_watcher_healthy for that.
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_SUPERVISABLE=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
    # A detached task demands no live watcher (user-driven, no CI polling);
    # every other meta - including a released one, whose PR CI the watcher still
    # polls - does. Presence of the `detached=` marker is the whole test.
    grep -q '^detached=' "$meta" 2>/dev/null && continue
    FM_SUP_SUPERVISABLE=$((FM_SUP_SUPERVISABLE + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      # shellcheck disable=SC2034 # Descriptive age band read by callers/tests after sourcing.
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}
