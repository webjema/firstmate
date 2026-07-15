#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# busy pane signature), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. A declared external-wait pause is
# the separate idle absorb case and re-surfaces only on its long bounded cadence,
# although its initial no-verb status signal still surfaces in normal mode.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake.
#
# Every printed (and enqueued) reason is a FAT PAYLOAD - one line that carries the
# evidence this watcher already computed, so the supervisor re-derives nothing:
#   <kind>: <target> | task=<id> class=<verdict> [<field>=<value> ...] last=<status-line>
# bin/fm-classify-lib.sh's wake_payload owns that grammar and its field vocabulary.
# Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active. One
#                          evidence block per referenced task, separated by " ; ".
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it a follow-up. A declared
#                          external-wait pause is absorbed instead with its own long
#                          re-surface cadence, never as a wedge. Only when neither
#                          absorb class applies does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with a "wedge=N"
#                          count in the payload; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the payload
#                          also carries "demand-deep-inspection=1" so the
#                          wake itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless afk is active.
#   check: <script>: <out> per-task check output, always actionable
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Shared wake classifier (captain-relevant verbs + signal/stale/heartbeat
# predicates), the SAME library the away-mode daemon uses, so the triage policy
# has one definition.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# The EVENT SOURCE: this watcher's poll loop over the pull primitives (capture,
# recorded windows, and the BUSY_REGEX pane-tail match) synthesizes the
# signal/stale/check/heartbeat wake vocabulary. tmux has no native event push, so
# this poll loop is the whole supervision surface. See bin/fm-backend.sh.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions and
# returns before acquiring the lock or starting the loop. Running it as a script
# executes the runtime.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working...";
# grok: "Ctrl+c:cancel" (the mid-turn cancel hint in grok's keybind bar, shown iff a
# turn is running; absent when idle - verified grok 0.2.73, ASCII to avoid the
# locale fragility of matching grok's braille spinner glyph directly).
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'}
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
WT_FRESH_SECS=${FM_WT_FRESH_SECS:-120}    # worktree moved this recently => a positive working signal, no pane probe
WT_STILL_SECS=${FM_WT_STILL_SECS:-1800}   # worktree unmoved this long on a LIVE pane => spinning; 0 disables
# A crew that DECLARED a pause (paused: <reason>, fm-classify-lib.sh) is idling on
# a known external wait, so its stale pane is absorbed rather than wedge-escalated;
# it re-surfaces once for a recheck every PAUSE_RESURFACE_SECS - far longer than the
# wedge threshold, but finite so a forgotten pause cannot rot invisibly.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

# Append one line to the triage debug log explaining an absorbed (benign) wake,
# size-capped so a long benign stretch cannot grow it without bound. Best-effort:
# a logging hiccup never affects supervision.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is actively working. tmux has
# no native busy state, so this is the pane-tail regex over the last 6 non-blank
# lines (the TUI footer area, where every verified harness renders its busy
# indicator). <tail40> is the same bounded capture already read for hashing, so
# this adds no extra backend calls.
window_is_busy() {  # <window> <tail40>
  local tail40=$2
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
}

# The one-line payload for a signal wake: the historical "signal: <files>" target,
# then one evidence block per distinct task, blocks separated by " ; ". Called ONLY
# on the surfacing path, so the absorb-verdict probe it pays for is spent on a wake
# that is actually going out. Under afk the daemon owns triage and probes for
# itself, so the watcher records `untriaged` rather than probing twice.
signal_payload() {  # <state> <file>...
  local state=$1 f base task class seen="" ev="" dkey
  shift
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    if afk_present; then class=untriaged; else class=$(crew_absorb_class "$task"); fi
    [ -n "$ev" ] && ev="$ev ; "
    # A still-open decision rides the payload, because last= alone can hide one: the
    # crew's later working: note is the last line, but the question is still unanswered.
    dkey=$(status_open_decision_key "$state/$task.status" || true)
    if [ -n "$dkey" ]; then
      ev="$ev$(wake_evidence "$state" "$task" "$class" "open-decision=$dkey")"
    else
      ev="$ev$(wake_evidence "$state" "$task" "$class")"
    fi
  done
  if [ -n "$ev" ]; then
    printf 'signal: %s | %s' "$*" "$ev"
  else
    printf 'signal: %s' "$*"
  fi
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

window_worktree() {
  local w=$1 meta
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  fm_meta_get "$meta" worktree 2>/dev/null || true
}

# Watch the WORK, not just the screen. The pane lies in both directions: a crew
# committing steadily but quiet for five minutes has a static pane and looks
# wedged, while a crew spinning without touching a file has a lively pane and looks
# alive. bin/fm-wt-activity-lib.sh reads the worktree, which cannot fake either.
#
# Prints "<class> <age-secs>", where class is:
#   fresh - the worktree ADVANCED since the last poll, or within WT_FRESH_SECS: a
#           positive working signal, free of any pane probe;
#   still - the worktree has not moved for WT_STILL_SECS: the wedge signal the
#           pane-hash heuristic structurally cannot see;
#   quiet - neither. No evidence, so the caller falls back to its pane/status
#           evidence exactly as before.
# The FIRST snapshot of a task is `quiet`, never `fresh`: a watcher that restarted
# next to an already-dead crew must not read its own ignorance as progress.
# Cheap enough for every poll by construction (see the probe's cost bound).
wt_track() {  # <task> <worktree>
  local task=$1 wt=$2 snap prev snapf sincef now since age
  [ -n "$task" ] && [ -n "$wt" ] || { printf 'quiet 0'; return; }
  snap=$(wt_activity_snapshot "$wt" "$STATE" "$task")
  [ -n "$snap" ] || { printf 'quiet 0'; return; }
  snapf="$STATE/.wt-snap-$task"
  sincef="$STATE/.wt-since-$task"
  prev=$(cat "$snapf" 2>/dev/null || true)
  now=$(date +%s)
  if [ -z "$prev" ]; then
    printf '%s\n' "$snap" > "$snapf"
    printf '%s\n' "$now" > "$sincef"
    printf 'quiet 0'
    return
  fi
  if wt_activity_advanced "$prev" "$snap"; then
    printf '%s\n' "$snap" > "$snapf"
    printf '%s\n' "$now" > "$sincef"
    rm -f "$STATE/.wt-still-woke-$task"
    printf 'fresh 0'
    return
  fi
  since=$(cat "$sincef" 2>/dev/null || true)
  case "$since" in ''|*[!0-9]*) since=$now; printf '%s\n' "$now" > "$sincef" ;; esac
  age=$(( now - since ))
  [ "$age" -lt 0 ] && age=0
  if [ "$age" -lt "$WT_FRESH_SECS" ]; then printf 'fresh %s' "$age"; return; fi
  if [ "$WT_STILL_SECS" -gt 0 ] && [ "$age" -ge "$WT_STILL_SECS" ]; then printf 'still %s' "$age"; return; fi
  printf 'quiet %s' "$age"
}

# A crew whose PANE keeps changing but whose WORKTREE has not moved for
# WT_STILL_SECS is spinning: reading, re-planning, looping on tool calls, producing
# screen but not work. Nothing else in this watcher can see it - the pane never goes
# stale, so no stale wake ever fires and the heartbeat is its only backstop.
# Surfaced ONCE per stillness episode (the marker is cleared the moment the worktree
# moves again), and deliberately narrow:
#   - ship tasks only: a scout's deliverable is a REPORT outside the worktree, so a
#     scout that touches no tracked file is doing exactly its job;
#   - not while the pane shows a busy signature: a long build or test run is
#     legitimately still, and its harness says so;
#   - not for a declared pause, and not under afk (the daemon owns triage);
#   - default WT_STILL_SECS is deliberately long (30 minutes), because the cost of a
#     false wake is a wasted firstmate turn and the cost of a late one is minutes.
# FM_WT_STILL_SECS=0 disables it.
surface_still_worktree() {  # <window> <task> <kind> <age> <tail40>
  local w=$1 task=$2 kind=$3 age=$4 tail40=$5 reason
  [ "$WT_STILL_SECS" -gt 0 ] || return 0
  [ "$kind" = ship ] || return 0
  afk_present && return 0
  [ -e "$STATE/.wt-still-woke-$task" ] && return 0
  window_is_busy "$w" "$tail40" && return 0
  status_is_paused "$(last_status_line "$STATE/$task.status")" && return 0
  reason=$(wake_payload stale "$w" "$STATE" "$task" spinning "wt=still" "idle=${age}s")
  fm_wake_append stale "$w" "$reason" || exit 1
  date +%s > "$STATE/.wt-still-woke-$task"
  wake "$reason"
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crew
# state (the costly check already ran once, at classification time). Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a captain-relevant status-log
# line that an active run/busy pane outranked).
# <class> is the absorb verdict the CALLER actually derived from a probe. It is a
# parameter, not a constant, because the payload must never state a verdict nobody
# computed: an earlier cut of this branch hard-coded `working` here and reached it
# from a path that had taken no probe at all, so the wake asserted a working crew
# that had in fact stopped. Every call site below is downstream of a
# crew_absorb_class read that returned `working`, and says so.
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file> <class>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 class=$5 since age n reason extra
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        extra="idle=${age}s wedge=$n"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          extra="$extra demand-deep-inspection=1"
        fi
        # shellcheck disable=SC2086  # $extra is a deliberate multi-field split.
        reason=$(wake_payload stale "$win" "$STATE" "$(window_to_task "$win" "$STATE")" "$class" $extra)
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        wake "$reason"
      fi
      ;;
  esac
}

# Absorb a stale pane whose crew is in a DECLARED external-wait pause (paused:),
# and re-surface it once every PAUSE_RESURFACE_SECS for a recheck so it cannot rot
# invisibly. Called on any stale poll once the crew is known paused (first sight,
# after crew_absorb_class; and repeat sights, gated by the .paused-<key> flag), so
# it must be cheap: it NEVER re-reads the crew state. The re-surface age is anchored
# on the pause's own STATUS-FILE mtime, not a per-hash marker, so a churny idle pane
# (a ticking clock, a token counter) cannot keep resetting the cadence the way a
# hash-tied timer would. A .paused-resurfaced-<key> throttle marker records the last
# re-surface epoch so, once past the window, it fires once per window rather than
# every poll. Advances the stale suppressor to <hash> and flags the key paused.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age rf rf_age reason
  key=$(printf '%s' "$win" | tr ':/.' '___')
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason=$(wake_payload stale "$win" "$STATE" "$task" paused "idle=${age}s" "recheck=pause")
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
  fi
  triage_log "absorbed stale (paused, awaiting external, age ${age}s): $win"
}

clear_pause_state() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  clear_pause_state "$win"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
}

pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

# Surface a stale pane whose crew is NOT provably working and not paused: it
# stopped. The payload carries the absorb verdict (class=none) and the crew's
# last status line, so the wake needs no follow-up status read.
surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key reason
  key=$(printf '%s' "$win" | tr ':/.' '___')
  reason=$(wake_payload stale "$win" "$STATE" "$(window_to_task "$win" "$STATE")" none)
  fm_wake_append stale "$win" "$reason" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
  wake "$reason"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

run_check() {
  local c=$1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  fi
}

# Surfaced-marker bookkeeping for the heartbeat backstop. The watcher records the
# captain-relevant status line it SURFACED (woke firstmate for) in
# .hb-surfaced-<task>, the watcher's analogue of the daemon's
# .subsuper-seen-status. Unlike .seen-* (a size:mtime signature advanced on BOTH
# surface and absorb), .hb-surfaced is advanced ONLY on surface, so the heartbeat
# fleet-scan can tell apart a captain-relevant status that already woke firstmate
# from one that has not - the latter being a per-wake-path miss it must surface.
_hb_surfaced_path() { printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"; }

# Record a status file's captain-relevant last line as surfaced (no-op for a
# non-captain-relevant or empty status). Call AFTER the wake is enqueued, so the
# enqueue-before-suppress ordering holds for this marker too.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Daemon-leak containment: refuse to take a home lock that belongs to a DIFFERENT
# firstmate checkout than the one this watcher was launched from. Without this, a
# watcher started from a crew worktree whose $FM_HOME resolves to the real home
# (no FM_STATE_OVERRIDE) would seize the real home's .watch.lock and evict the
# primary's watcher - a crewmate merely running the test suite could silently
# switch off supervision of the whole fleet. See fm-wake-lib.sh's
# fm_home_lock_is_foreign for the exact predicate; FM_STATE_OVERRIDE (every test)
# and a watcher run from its own home both pass it.
if fm_home_lock_is_foreign "$WATCH_PATH" "$FM_HOME" "${FM_STATE_OVERRIDE:-}"; then
  echo "watcher: refusing foreign home lock - FM_HOME=$FM_HOME has its own checkout ($FM_HOME/bin/fm-watch.sh), not this watcher ($WATCH_PATH). Run the watcher from that home, or set FM_STATE_OVERRIDE for an isolated run." >&2
  exit 3
fi

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
trap 'fm_lock_release "$WATCH_LOCK"' EXIT
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    # Pool warming rides this SLOW cadence, never the 15s poll: keep one free warm
    # slot ready for every project with work in flight, so a crew never pays the
    # cold dependency install on the spawn path (a measured 137s for optiroq; see
    # bin/fm-pool-warm.sh, which owns the policy). Launched DETACHED and never
    # waited on - warming takes minutes, and the watcher must not miss a wake
    # while it runs. It is a short-lived child of the watcher, not a new always-on
    # process. A failed warm logs and retires quietly; it can never break a spawn
    # or wake the user, so its exit status is deliberately ignored here.
    # The overrides ride along explicitly: this watcher resolved STATE/CONFIG from
    # them, and they are plain shell vars here, not exported - so a home running on
    # an override would otherwise have its warmer write to a DIFFERENT state dir
    # than the one the watcher is watching.
    if [ "${FM_POOL_WARM:-1}" = 1 ] && [ -x "$SCRIPT_DIR/fm-pool-warm.sh" ]; then
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
        FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-}" \
        nohup "$SCRIPT_DIR/fm-pool-warm.sh" >/dev/null 2>&1 &
      disown 2>/dev/null || true
    fi
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      out=$(run_check "$c")
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) that is not
    #     ABSORBABLE - neither its turn-end body nor its endpoint proves the crew is
    #     still moving, so it may be done (even via an interactive menu that wrote no
    #     done: status), waiting on a decision, or wedged. Absorbing such a turn-end
    #     is exactly the swallowed-finish this guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign in always-on mode
    # -> advance the markers so it will not re-fire, log, and keep blocking without
    # enqueuing. signal_crew_absorbable is the only costly check (and only in its
    # second leg: a turn-end body that shows progress absorbs for free, with no pane
    # probe), so the || ordering evaluates it ONLY for a non-afk, no-user-verb
    # signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_reason_is_actionable $files \
       || signal_has_new_open_decision "$STATE" $files \
       || ! signal_crew_absorbable "$STATE" $files; then
      # The wake is going out, so pay for its evidence ONCE here, in bash: each
      # referenced task's absorb verdict and last status line ride the payload,
      # and the orchestrator re-reads nothing for the common case. The verdict is
      # `untriaged` under afk (the daemon owns triage and probes for itself).
      # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
      reason=$(signal_payload "$STATE" $files)
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
      turnend_record_seen "$STATE" $files
      # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
      decision_record_seen "$STATE" $files
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
      turnend_record_seen "$STATE" $files
      # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
      decision_record_seen "$STATE" $files
      triage_log "absorbed benign signal:$files"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=${w//:/_}
    key=${key//\//_}
    key=${key//./_}
    last=$(last_status_line "$STATE/$task.status")
    if ! status_is_paused "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$w"
    fi
    # An idle secondmate is healthy BY CHARTER, so its idle pane is never a wedge and
    # is skipped exactly as before. A secondmate with LIVE WORK is a different animal:
    # it took a routed request, or has crew of its own in flight, and a frozen pane
    # then means the same thing it means for a crewmate. The blanket skip made that
    # wedge silent forever (fm-classify-lib.sh owns the live-work test).
    if [ "$kind" = secondmate ] && ! status_is_paused "$last" \
       && ! secondmate_has_live_work "$STATE" "$task"; then
      continue
    fi
    tail40=$(fm_backend_capture tmux "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
    # The worktree read runs every poll for every window, before any pane triage:
    # it is the cheap evidence, and both branches below consult it.
    read -r wtclass wtage <<EOF
$(wt_track "$task" "$(window_worktree "$w")")
EOF
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's current stale is a declared pause
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Busy match: the last 6 non-blank lines only (the TUI footer area, where
      # every verified harness renders its busy indicator) so busy-looking
      # strings in displayed content cannot suppress stale detection.
      if [ "$n" -ge 2 ] && ! window_is_busy "$w" "$tail40"; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused)  handle_paused_stale "$w" "$task" "$h" ;;
            working) clear_pause_tracking "$w" ;;
            *)
              # clear_pause_STATE, not clear_pause_TRACKING: the latter deletes
              # .stale-<key> ($sf), which is the very suppressor the guard below
              # reads. Clearing it first made that guard always true, so a wedged
              # secondmate re-woke firstmate on EVERY poll, forever - and firstmate
              # cannot un-wedge a secondmate in one turn, so the loop never ended.
              # Only the pause flags are cleared here; the stale hash is the record of
              # "already surfaced" and is written below.
              clear_pause_state "$w"
              # Not paused, not working, and its pane has been frozen across two
              # polls while work is outstanding: this is the wedged secondmate the
              # blanket skip used to hide. Once per distinct stale hash, like any
              # other crew - an idle secondmate never reaches here at all.
              if secondmate_has_live_work "$STATE" "$task" \
                 && [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
                reason=$(wake_payload stale "$w" "$STATE" "$task" none "kind=secondmate")
                fm_wake_append stale "$w" "$reason" || exit 1
                printf '%s' "$h" > "$sf"
                mark_surfaced "$STATE/$task.status"
                wake "$reason"
              fi
              ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before. The
          # watcher deliberately does not probe the crew here (that is the
          # daemon's job), so the payload's verdict is `untriaged`.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            reason=$(wake_payload stale "$w" "$STATE" "$task" untriaged)
            fm_wake_append stale "$w" "$reason" || exit 1
            printf '%s' "$h" > "$sf"
            wake "$reason"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it a follow-up
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            else
              reason=$(wake_payload stale "$w" "$STATE" "$task" none)
              fm_wake_append stale "$w" "$reason" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              mark_surfaced "$STATE/$task.status"
              wake "$reason"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf" working
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly run-step read runs only
          # on first sight, never every poll) via crew_absorb_class, which returns
          # BOTH absorb reasons from one fm-crew-state.sh read:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: the crew DECLARED an external wait (paused:), so absorb on the
          #     long PAUSE_RESURFACE_SECS recheck cadence instead of wedge-escalating;
          #   - none: no running pipeline, idle pane, no busy signature, no declared
          #     pause - the crew has STOPPED. Surface immediately so firstmate peeks
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            # The worktree is deliberately NOT consulted here. A fresh worktree is
            # PAST evidence - it says the crew did work recently, never that it is
            # alive NOW - and an idle pane over a fresh worktree is precisely the
            # swallowed finish: the crew made its final commit and stopped. An earlier
            # cut of this branch absorbed on that signal, which made a stopped crew
            # wait out FM_STALE_ESCALATE_SECS where main surfaced it instantly, and
            # made the resulting payload claim class=working without ever probing.
            # Only the probe answers "alive now", so only the probe decides here.
            case "$(crew_absorb_class "$task")" in
              working)
                clear_pause_tracking "$w"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$w"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf" working
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       surface_nonterminal_stale "$w" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf" working
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping.
        rm -f "$ssf" "$ewf"
        if [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      rm -f "$ssf" "$ewf"
      task=$(window_to_task "$w" "$STATE")
      if ! afk_present && status_is_paused "$(last_status_line "$STATE/$task.status")" && ! window_is_busy "$w" "$tail40"; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$w" ;;
        esac
      else
        [ -e "$pf" ] && clear_pause_tracking "$w"
        # The pane changed, so no stale wake will ever fire for this crew. That is
        # exactly where a spinning crew hides: lively screen, motionless work.
        if [ "$wtclass" = still ]; then
          surface_still_worktree "$w" "$task" "$kind" "$wtage" "$tail40"
        fi
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: the poll sleep. tmux has no native event push, so the poll
  # loop above is the whole event source.
  sleep "$POLL"
done
