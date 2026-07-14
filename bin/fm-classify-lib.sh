#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# The one exception is the absorb classification (crew_absorb_class and its
# working/paused wrappers). It is NOT a pure status-file read: it reuses
# bin/fm-crew-state.sh, which probes the crew's recorded backend endpoint, to
# decide whether a crew that just stopped its turn or went stale is working,
# deliberately paused, or neither. Callers run it ONLY on no-verb signal handling
# and first sighting of a stale hash, never on every wake, so the per-wake triage
# stays cheap.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The worktree-activity probe. It owns the snapshot grammar and the progress rule;
# this lib only decides what a supervisor should DO with a verdict.
# shellcheck source=bin/fm-wt-activity-lib.sh
. "$_FM_CLASSIFY_LIB_DIR/fm-wt-activity-lib.sh"

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the pane/log verdict without a real worktree or a
# live backend endpoint; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status VERBS. A status line whose LEADING VERB is one of these is
# work firstmate must see. Lines with any other verb are no-verb signals: the watcher
# absorbs them only with positive evidence the crew is still moving, while the daemon
# uses its away-mode classification.
#
# Relevance is anchored to the verb, never to a substring of the prose, because the
# note after the verb is free text written by a crewmate. Scanning the whole line
# escalated "working: rebased onto merged main" as captain-relevant - the word
# `merged` appearing anywhere was enough - and burned a full firstmate turn on a
# routine progress note. The verb is the crew's actual claim; everything after the
# colon is commentary.
FM_CLASSIFY_CAPTAIN_VERBS='done needs-decision blocked failed'

# The whole-line regex is now ONLY the explicit escape hatch: a home that sets
# FM_CAPTAIN_RE is deliberately asking for its own vocabulary, matched against the
# whole line, and gets exactly that. This default is what such a home starts from,
# and is never applied on its own - with FM_CAPTAIN_RE unset, the verb set above is
# the entire test.
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause. Far longer than the wedge
# threshold (FM_STALE_ESCALATE_SECS, default 240s) so a deliberate wait is not
# nagged like a wedge, yet finite so a forgotten pause cannot rot invisibly - it
# re-surfaces once for a recheck every window. One hour by default; both consumers
# read FM_PAUSE_RESURFACE_SECS with this default so the cadence has one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# The resolution verb that CLOSES a keyed decision opened by needs-decision or
# blocked. See status_open_decisions below for the full durable-decision contract;
# this is the one owner of the verb literal, overridable via FM_CLASSIFY_RESOLVE_VERB.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line is captain-relevant: its LEADING VERB is one of
# FM_CLASSIFY_CAPTAIN_VERBS. The note after the verb is never scanned - a crewmate
# writing "working: rebased onto merged main" is reporting progress, not a merge.
# A home that sets FM_CAPTAIN_RE has explicitly asked for a whole-line regex instead,
# and gets exactly that, verb anchoring included or not as it chooses.
status_is_captain_relevant() {
  local line=$1 verb v
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  if [ -n "${FM_CAPTAIN_RE+x}" ]; then
    printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
    return
  fi
  verb=$(status_line_verb "$line")
  for v in $FM_CLASSIFY_CAPTAIN_VERBS; do
    [ "$verb" = "$v" ] && return 0
  done
  return 1
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the contract that fixes this - a needs-decision/blocked line OPENS a
# keyed decision, and ONLY an explicit resolution referencing that key CLOSES it; a
# later unrelated terminal line never clears an open captain decision.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token sits between the verb and the colon,
#   needs-decision [key=api-shape]: <summary>
#   resolved       [key=api-shape]: <how it was decided>
# A line with no token uses the key "default", preserving the historical
# one-open-decision-per-task behavior (a bare "resolved:" closes "default").
# The three parsers are pure reads of a single line; the verb parser strips any
# key token before the colon so the leading word is recovered cleanly.
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local prefix=${1%%:*} k
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *) printf 'default' ;;
  esac
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read of
# the file, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
status_open_decisions() {  # <status-file>
  local f=$1 line verb key note resolve open='' stripped
  [ -f "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      needs-decision|blocked)
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      "$resolve")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# --- wake payloads ----------------------------------------------------------
#
# THE ONE OWNER of the wake-payload grammar. Every wake the watcher prints (and
# enqueues) carries, on ONE line, the evidence the watcher already computed, so
# the orchestrator never re-derives a fact bash held in a variable:
#
#   <kind>: <target> | task=<id> class=<verdict> [<field>=<value> ...] last=<status-line>
#
# The part before " | " is the historical target (a status-file list for
# `signal:`, a window for `stale:`) and stays first so a consumer that only wants
# the target can cut at the separator - which bin/fm-supervise-daemon.sh's
# handle_wake does. `last=` is always the FINAL field because a status note is
# free text and may contain anything, including a `=` or a `|`.
#
# Fields:
#   task=  the task id the wake is about
#   class= the crew_absorb_class verdict at wake time: working | paused | none;
#          `spinning` when the worktree probe found a LIVE pane over a motionless
#          worktree (no pane probe was needed, or taken); or `untriaged` when the
#          away-mode daemon owns triage and the watcher deliberately did not probe
#   idle=  seconds the pane has been idle (stale wakes, where known)
#   wedge= consecutive wedge escalations on this same unchanged pane
#   demand-deep-inspection=1  at FM_WEDGE_DEMAND_INSPECT_COUNT escalations
#   recheck=pause  the bounded re-surface of a declared external wait
#   wt=still  the worktree has not moved for FM_WT_STILL_SECS (pairs with class=spinning)
#   open-decision=<key>  a decision the crew opened is STILL OPEN in the durable fold,
#          even if a later line masks it as `last=` (status_open_decisions owns the fold)
#   kind=secondmate  a wedged secondmate with live work (an idle one is healthy, and silent)
#   last=  the last non-blank status line, verbatim, or `(none)`
#
# A payload is a token diet, not a new verbosity: one line, no prose.
wake_evidence() {  # <state> <task> <class> [extra-field ...]
  local state=$1 task=$2 class=$3 last
  shift 3
  last=$(last_status_line "$state/$task.status")
  [ -n "$last" ] || last='(none)'
  printf 'task=%s class=%s' "$task" "$class"
  [ "$#" -gt 0 ] && printf ' %s' "$*"
  printf ' last=%s' "$last"
}

wake_payload() {  # <kind> <target> <state> <task> <class> [extra-field ...]
  local kind=$1 target=$2 state=$3 task=$4 class=$5
  shift 5
  printf '%s: %s | %s' "$kind" "$target" "$(wake_evidence "$state" "$task" "$class" "$@")"
}

# The target half of a payload: everything before the evidence separator. The
# inverse of wake_payload for a consumer that wants the window or file list back.
wake_payload_target() {  # <reason-after-the-kind-prefix>
  printf '%s' "${1%% | *}"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - a busy endpoint signature: the crew is legitimately mid-turn or
#             mid-tool-call on a static-looking pane (a long test run, a review
#             pass), so its stopped-looking wake is benign;
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/needs-decision/
#             failed/torn-down/unknown crew, or an unreadable verdict).
# One fm-crew-state.sh read serves BOTH absorb reasons at once. The source check is
# what keeps this POSITIVE evidence: only a live endpoint read (`pane`) proves the
# crew is working, never a `working:` line left behind in the status log. A crew
# that appended paused: but is now busy reports working, never paused.
# (`run-step` is the retired token of the removed external-pipeline source; it is
# still accepted so stubbed verdicts in existing watcher tests keep classifying,
# and can be dropped once those stubs move to `pane`.)
# NOT a pure read: fm-crew-state.sh probes the recorded backend endpoint, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in pane|run-step) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`, i.e. a busy endpoint signature). This is the "provably
# working" predicate at the heart of absorb-only-when-provably-working: a no-verb
# turn-end or stale wake is absorbed ONLY when this returns 0, and SURFACED
# otherwise (the crew may be done, waiting on a decision, or wedged). For stale
# panes it is checked before trusting the status log so an old captain-relevant
# line does not override a crew that has since resumed work.
# See crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
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
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# --- turn-end bodies --------------------------------------------------------
#
# A turn-end marker carries a BODY (bin/fm-turnend-mark.sh owns its format): the
# turn counter plus the worktree snapshot taken as the turn ended. Comparing this
# turn's snapshot with the one recorded at the PREVIOUS turn end answers, for
# free, the question the watcher used to pay a pane probe to answer: did that turn
# actually move the work?
#
# `turnend_shows_progress` is deliberately conservative. It absorbs ONLY on
# positive evidence of movement (a commit, a stage, an edit). No body, no previous
# body, or an unchanged worktree all return 1, and the caller falls back to the
# pane probe exactly as before - a wedged crew is never absorbed by silence.
#
# Absorbing here does NOT hide a finished crew: a crew that is truly done says so
# with a captain-relevant verb (which surfaces on the status signal), and a crew
# that stops for any other reason goes stale, which the stale path surfaces.
# All this removes is the pane probe and the peek for the routine case: a crew that
# committed something and carried on.
turnend_shows_progress() {  # <state> <task>
  local state=$1 task=$2 body prev
  body=$(head -1 "$state/$task.turn-ended" 2>/dev/null || true)
  prev=$(head -1 "$state/.turnend-seen-$task" 2>/dev/null || true)
  wt_activity_advanced "$prev" "$body"
}

# Record the turn-end bodies just handled, so the NEXT turn end has something to
# compare against. Consumer bookkeeping, called once per handled signal whether it
# was surfaced or absorbed - the same discipline the watcher's .seen-* signatures
# follow, so a watcher killed mid-cycle re-handles rather than swallows.
turnend_record_seen() {  # <state> <file> ...
  local state=$1 f base task body
  shift
  for f in "$@"; do
    base=${f##*/}
    case "$base" in *.turn-ended) task=${base%.turn-ended} ;; *) continue ;; esac
    body=$(head -1 "$state/$task.turn-ended" 2>/dev/null || true)
    [ -n "$body" ] || continue
    printf '%s\n' "$body" > "$state/.turnend-seen-$task" 2>/dev/null || true
  done
  return 0
}

# 0 if the crew's WORKTREE has advanced since the watcher last recorded it: positive
# working evidence taken from the work itself rather than from the screen, and free
# of any pane probe. Reads the recorded snapshot the watcher's per-poll tracker
# owns (state/.wt-snap-<task>) and mutates nothing, so calling it never consumes the
# movement the tracker is about to see. No recorded snapshot, no worktree in the
# task's meta, or an unprobeable worktree all return 1 - no evidence is not progress.
crew_worktree_advanced() {  # <state> <task>
  local state=$1 task=$2 prev wt now
  prev=$(head -1 "$state/.wt-snap-$task" 2>/dev/null || true)
  [ -n "$prev" ] || return 1
  wt=$(grep '^worktree=' "$state/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] || return 1
  now=$(wt_activity_snapshot "$wt" "$state" "$task")
  wt_activity_advanced "$prev" "$now"
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake can be
# absorbed, by ANY of three independent positive-evidence tests, cheapest first:
#   1. its turn-end body proves the turn moved the work (free);
#   2. its worktree has advanced since the watcher last looked (one git read);
#   3. the crew is provably working on its endpoint (one pane probe).
# The two free tests come first, so the common cases - a crew that ended a turn
# having committed something, or one that files a `working:` note mid-commit - cost
# no probe at all. 1 (surface) if a referenced task passes none of the three, or if
# no task can be resolved.
signal_crew_absorbable() {  # <state> <file> ...
  local state=$1 f base task seen=""
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
    turnend_shows_progress "$state" "$task" && continue
    crew_worktree_advanced "$state" "$task" && continue
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# --- secondmates: idle is healthy, wedged is not ----------------------------
#
# A secondmate is idle BY CHARTER when nothing is routed to it, so its idle pane is
# not a wedge and must never be surfaced - which is why the watcher skipped stale
# detection for secondmates entirely. The cost of that blanket skip was a silent
# hole: a secondmate that wedged mid-task produced no stale wake at all, ever.
#
# The discriminator is LIVE WORK: does its own home hold at least one task meta -
# crew of its own, in flight? A secondmate supervising crew MUST be alive to
# supervise it, so a pane frozen across two polls while its children run means its
# whole fleet is unwatched, which is the wedge worth waking firstmate for. A
# secondmate with no crew in flight is idle, and stays as silent as it is today.
#
# Deliberately NOT part of the test: the secondmate's own `working:` status line. A
# secondmate writes one while merely standing by ("working: the parent supervises
# this secondmate"), so it says nothing about whether work is outstanding - using it
# would surface every healthy idle secondmate, which is exactly what must not happen.
# The honest limit of this test: a secondmate that wedges BEFORE spawning any crew
# has produced no live-work evidence anywhere, and stays invisible to the stale path.
# Its routed request is not lost - an open needs-decision or blocked still reaches
# firstmate through the signal path and the open-decision fold.
secondmate_has_live_work() {  # <state> <task>
  local state=$1 task=$2 home meta
  [ -n "$task" ] || return 1
  home=$(grep '^home=' "$state/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$home" ] || return 1
  for meta in "$home"/state/*.meta; do
    [ -e "$meta" ] && return 0
  done
  return 1
}

# --- open decisions must not be masked --------------------------------------
#
# status_open_decisions folds the WHOLE log into the decisions still open, but the
# watcher's triage only ever read the LAST line. So a still-open needs-decision
# followed by any later `working:` line was invisible to the wake path: the crew's
# question sat unasked until a slow backstop happened to notice. The signature below
# lets the wake path consume the fold.
#
# It is a signature, not a boolean, so the wake stays NARROW: firstmate is woken when
# the open SET CHANGES (a new or different decision is open), not on every later line
# while a known decision stays open. An already-surfaced decision that firstmate is
# still thinking about must not re-wake it on the crew's next progress note.
status_open_decision_sig() {  # <status-file>
  local open
  open=$(status_open_decisions "$1")
  [ -n "$open" ] || return 0
  printf '%s' "$open" | tr '\n\t' '; '
}

# The key of the most recently opened still-open decision, for the wake payload.
status_open_decision_key() {  # <status-file>
  local open
  open=$(status_open_decisions "$1")
  [ -n "$open" ] || return 1
  printf '%s' "$open" | tail -1 | cut -f1
}

# 0 (actionable) if any status file in a signal wake has a still-open decision whose
# open-set signature this watcher has not surfaced yet.
signal_has_new_open_decision() {  # <state> <file> ...
  local state=$1 f base task sig
  shift
  for f in "$@"; do
    base=${f##*/}
    case "$base" in *.status) task=${base%.status} ;; *) continue ;; esac
    sig=$(status_open_decision_sig "$f")
    [ -n "$sig" ] || continue
    [ "$sig" = "$(cat "$state/.decision-seen-$task" 2>/dev/null || true)" ] && continue
    return 0
  done
  return 1
}

# Record the open-decision signatures just handled, so an open decision that stays
# open does not re-wake firstmate on the crew's next line. Same discipline as the
# .seen-* signatures: written whether the wake surfaced or was absorbed.
decision_record_seen() {  # <state> <file> ...
  local state=$1 f base task sig
  shift
  for f in "$@"; do
    base=${f##*/}
    case "$base" in *.status) task=${base%.status} ;; *) continue ;; esac
    sig=$(status_open_decision_sig "$f")
    if [ -n "$sig" ]; then
      printf '%s' "$sig" > "$state/.decision-seen-$task" 2>/dev/null || true
    else
      rm -f "$state/.decision-seen-$task" 2>/dev/null || true
    fi
  done
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
