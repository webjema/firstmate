#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes, the log's last line stays stale. This helper
# never infers the current state from a tail of the log alone: it reads the live
# source first (the recorded endpoint's busy signature) and only then reconciles
# the possibly-stale log against it.
#
# The determinism lives entirely here - only pane / log reads plus fixed mapping
# logic, no heuristics and no LLM. Output is one stable, parseable, token-tight
# line firstmate can read every heartbeat:
#
#   state: <working|needs-decision|blocked|paused|done|failed|unknown> · source: <pane|status-log|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta.
#   2. Missing meta or torn-down worktree: report unknown · none.
#   3. No recorded backend target, or a target that is gone: report unknown · none
#      rather than trusting a possibly-stale status log for a crew that is no
#      longer there - with ONE exception: a last status line of `review-ready`
#      means the crew stopped ON PURPOSE and is parked waiting for firstmate, so a
#      missing window is EXPECTED, and it is read as review-ready from the log. No
#      other terminal verb relaxes this dead-crew guard.
#   4. A busy endpoint signature is POSITIVE evidence the crew is working, and
#      outranks the log: a crew mid-turn or mid-tool-call reports working even
#      when its last status line is an old needs-decision/blocked it has since
#      moved past. Secondmates are exempt (an idle secondmate pane is healthy).
#   5. Otherwise fall back to the status log's last line, but only when its verb
#      maps to a recognized state. Decision-only events such as `resolved` never
#      become current state or detail.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
# Map a status-log verb onto a canonical state. `paused` is the
# deliberate-external-wait verb (fm-classify-lib.sh's FM_CLASSIFY_PAUSED_VERB):
# a crew with an idle pane that declared a known external wait reports `paused`
# distinctly, so a supervisor reading this sees a declared pause and its reason
# rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  # Normalized, because status_normalize_verb owns the decoration/case rule and every
  # other verb test in the fleet goes through it. A crew whose harness capitalized its
  # verb is not in an "unknown" state.
  case "$(status_normalize_verb "$(status_line_verb "$1")")" in
    working)        echo working ;;
    needs-decision) echo needs-decision ;;
    blocked)        echo blocked ;;
    # A crew that has pushed and signalled review-ready is STOPPED ON PURPOSE, waiting for
    # firstmate. Reporting it as `unknown` made AGENTS.md section 7 read it as a dead or
    # wedged crew and route it to stuck-crewmate-recovery - which would interrupt or
    # relaunch the very crew that is patiently waiting to be reviewed.
    review-ready)   echo review-ready ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(status_line_verb "$LOG_LINE")

# Backend-aware endpoint reads (fm_backend_of_meta defaults an absent backend= to
# tmux, the P1 contract), so a herdr task is read through fm_backend_capture
# instead of a bare tmux probe.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    tmux) tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1 ;;
    *) fm_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# crew_pane_is_busy: the busy-signature read, backend-aware the same way -
# fm_backend_busy_state's native semantic state when a backend exposes one, else
# the shared tmux pane-regex reader (fm_pane_is_busy, bin/fm-tmux-lib.sh).
#
# A native `busy` is trusted outright. Both a native `idle` and an
# unknown/unparseable verdict fall through to the shared tail-regex
# corroboration, NOT just unknown: a backend's native state typically reports
# GENERATION state (the model is streaming a turn), which is narrower than "this
# crew's turn or tool call is still in progress". A crew blocked on its own
# long-running foreground tool call (a test run, a build, a review pass) is not
# generating for that whole span, so the native read can say idle while the pane's
# own rendered text still shows the harness's busy banner (BUSY_REGEX, e.g. "esc
# to interrupt") for the entire tool call, exactly as tmux's regex-only reader
# would correctly report. Trusting a native `idle` outright (skipping that
# corroboration) is what let a still-working crew read as not-busy here, and
# therefore as not provably working in fm-classify-lib.sh, triggering an immediate
# (non-wedge) stale wake instead of the absorb-then-escalate path. A genuinely
# human-blocked agent (a permission dialog, not mid-tool-call) does not render the
# busy banner, so this corroboration does not mask that case: it stays correctly
# not-busy.
crew_pane_is_busy() {  # <target>
  case "$TASK_BACKEND" in
    tmux) fm_pane_is_busy "$1" ;;
    *)
      local bs tail40
      bs=$(fm_backend_busy_state "$TASK_BACKEND" "$1" 2>/dev/null)
      case "$bs" in
        busy) return 0 ;;
        *)
          tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || return 1
          printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
            | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
          ;;
      esac
      ;;
  esac
}

# --- endpoint first, then the log ------------------------------------------
# A dead/unreadable backend target normally means the crew is GONE, so report
# unknown rather than trust a possibly-stale status log as the current state.
#
# The ONE exception is review-ready. It is the single verb that means "stopped ON
# PURPOSE - branch pushed, parked, waiting on firstmate's review", so a missing
# window is EXPECTED for such a crew, not a dead-crew fault. A review-ready crew's
# terminal genuinely can vanish (its harness exited, the pane was torn down) while
# the crew is by-design alive-but-parked on the remote. Reading review-ready from
# the log when the target is gone is what keeps that finished-and-waiting crew from
# being misread as `unknown` and routed to stuck-crewmate-recovery (AGENTS.md
# section 7), which would interrupt or relaunch the very crew that is patiently
# waiting. Every OTHER terminal verb still obeys the dead-crew guard: a stale
# working/needs-decision/blocked/paused/done/failed from a vanished crew stays
# unknown, because only review-ready means "deliberately parked on firstmate".
if [ -z "$BACKEND_TARGET" ] || ! pane_readable "$BACKEND_TARGET"; then
  if [ "$(map_log_state "$LOG_LINE")" = review-ready ]; then
    emit review-ready status-log "$(status_line_note "$LOG_LINE")"
  fi
  [ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
  emit unknown none "backend target gone: $BACKEND_TARGET"
fi

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# signature is not meaningful for them; read their state from the status log only.
# This exemption is also what keeps a secondmate's open decision visible through a
# busy pane, so do not "fix" it by treating a secondmate like a crewmate here: a
# wedged secondmate is distinguished in the watcher, by whether it has live work
# (fm-classify-lib.sh's secondmate_has_live_work), not by its busy signature.
if [ "$KIND" != secondmate ] && crew_pane_is_busy "$BACKEND_TARGET"; then
  # The busy pane is live evidence and outranks the log. A needs-decision/blocked
  # line the crew has since moved past is deterministically stale, so say so
  # instead of letting a raw tail of the log re-escalate settled work.
  case "$LOG_VERB" in
    needs-decision|blocked)
      emit working pane "harness busy${SEP}status-log superseded by busy pane"
      ;;
  esac
  emit working pane "harness busy"
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# state. A decision-closing event - resolved: (fm-classify-lib.sh's
# FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a secondmate, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

emit unknown none "no current-state source available"
