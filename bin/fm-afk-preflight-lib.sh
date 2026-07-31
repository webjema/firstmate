#!/usr/bin/env bash
# fm-afk-preflight-lib.sh - the ONE owner of "can away mode actually reach the
# supervisor pane?", run at away-mode ENTRY, before the daemon starts.
#
# WHY THIS EXISTS (incident afk-wake-fix-r4, 2026-07-26): away mode started
# cleanly, the user walked away, and only then did the daemon discover it could
# not deliver anything into firstmate's pane - a composer misclassification made
# every escalation defer. The buffer and wake queue were preserved perfectly and
# nothing was lost, but nothing arrived either, for 26,211 seconds. The user came
# back to one finished work package instead of three.
#
# The lesson is not "add another guard to the daemon" - the daemon already had
# guards, and a guard is what wedged. It is that away mode is a PROMISE to wake
# somebody, and a promise that cannot be demonstrated at the moment it is made
# must not be made at all. This preflight demonstrates it: it classifies the
# real supervisor composer through the real classifier and refuses to enter away
# mode unless the verdict is `empty`, the one state the injector will accept.
# Away mode that cannot prove a working wake path fails closed and says so,
# loudly and actionably, while the user is still at the keyboard.
#
# It refuses one case WITHOUT classifying: a supervisor target that was never
# resolved, only guessed from the built-in fallback. See fm_afk_preflight.
#
# Deliberately NOT checked: whether the pane is busy. firstmate is mid-turn
# running /afk at this very moment, so a busy pane is the normal case; the
# injector tolerates busy (a mid-turn harness queues the submitted digest) and
# the max-defer force escape bypasses the busy guard outright. The composer
# verdict is the thing that actually gates delivery, so it is the thing proved.
#
# FM_AFK_PREFLIGHT=0 skips the check. It exists for test harnesses and for a
# deliberate operator override; it is not a fix for a failing preflight, and a
# skipped preflight is logged by the caller as the reduced guarantee it is.

# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-backend.sh"

FM_AFK_PREFLIGHT_ATTEMPTS_DEFAULT=3
FM_AFK_PREFLIGHT_SLEEP_DEFAULT=0.5

# fm_afk_preflight_probe: classify the supervisor composer, retrying a few times
# so a transient mid-redraw read cannot fail an otherwise healthy pane. Prints
# the final verdict (empty|pending|unknown|missing).
fm_afk_preflight_probe() {  # <target> <backend>
  local target=$1 backend=$2 attempts sleep_s i=0 verdict=unknown
  attempts=${FM_AFK_PREFLIGHT_ATTEMPTS:-$FM_AFK_PREFLIGHT_ATTEMPTS_DEFAULT}
  sleep_s=${FM_AFK_PREFLIGHT_SLEEP:-$FM_AFK_PREFLIGHT_SLEEP_DEFAULT}
  while [ "$i" -lt "$attempts" ]; do
    if ! fm_backend_target_exists "$backend" "$target" 2>/dev/null; then
      printf 'missing'; return 0
    fi
    verdict=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
    [ "$verdict" = empty ] && { printf 'empty'; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$attempts" ] && sleep "$sleep_s"
  done
  printf '%s' "${verdict:-unknown}"
}

# fm_afk_preflight_explain: the actionable half of a refusal. Every branch says
# what was observed AND what to do about it, because this message is the last
# thing the user sees before they would otherwise have walked away.
fm_afk_preflight_explain() {  # <verdict> <target> <backend>
  local verdict=$1 target=$2 backend=$3
  echo "afk: REFUSING to enter away mode - cannot prove a working wake path." >&2
  echo "afk:   supervisor pane : $target (backend $backend)" >&2
  if [ "$verdict" = unresolved ]; then
    echo "afk:   resolution      : NOT DETECTED - this is the built-in fallback target" >&2
  else
    echo "afk:   composer verdict: $verdict (away mode delivers only into 'empty')" >&2
  fi
  case "$verdict" in
    unresolved)
      echo "afk:   firstmate is not running inside tmux, so nothing identified its own" >&2
      echo "afk:   pane and the target above is only a built-in guess. Whatever that pane" >&2
      echo "afk:   shows, it is not firstmate's, so no escalation can reach you through it." >&2
      echo "afk:   Run firstmate inside tmux, or set FM_SUPERVISOR_TARGET to its pane." >&2 ;;
    missing)
      echo "afk:   The supervisor pane does not exist. Set FM_SUPERVISOR_TARGET to the" >&2
      echo "afk:   pane running firstmate, or start away mode from that pane." >&2 ;;
    pending)
      echo "afk:   The composer holds unsubmitted text. Submit or clear the line, then" >&2
      echo "afk:   retry. If the line LOOKS empty, this is a classifier misread - capture" >&2
      echo "afk:   it with: tmux capture-pane -e -p -t $target -S \"\$(tmux display-message -p -t $target '#{cursor_y}')\" -E \"\$(tmux display-message -p -t $target '#{cursor_y}')\" | cat -A" >&2 ;;
    unknown)
      echo "afk:   The composer could not be read as a live agent composer (an unreadable" >&2
      echo "afk:   pane, or a bare shell prompt where the agent has exited). Check the pane" >&2
      echo "afk:   is running firstmate, then retry." >&2 ;;
  esac
  echo "afk:   Override with FM_AFK_PREFLIGHT=0 only if you accept that away mode may" >&2
  echo "afk:   not be able to wake you." >&2
}

# fm_afk_preflight: 0 when away mode may proceed, 1 when it must not. Resolves
# the target the same way the daemon will (discover_supervisor_target/backend,
# the shared owner) so the pane it proves is the pane the daemon will inject to.
fm_afk_preflight() {
  local target backend verdict resolved=1
  if [ "${FM_AFK_PREFLIGHT:-1}" = 0 ]; then
    echo "afk: preflight skipped (FM_AFK_PREFLIGHT=0); the wake path is UNVERIFIED" >&2
    return 0
  fi
  target=$(discover_supervisor_target) || resolved=0
  backend=$(discover_supervisor_backend) || true
  # An UNRESOLVED target is refused without probing, because the probe cannot
  # answer the question that matters. discover_supervisor_target returns 1 only
  # when nothing was configured and nothing was detected - i.e. firstmate is not
  # running inside tmux - and in that case no tmux pane can BE firstmate's own,
  # so the fallback names some unrelated pane. Its composer verdict is then pure
  # coincidence: an idle unrelated agent reads `empty` and would let away mode
  # promise a wake it structurally cannot deliver. The terminal-backed launcher
  # (fm_afk_launch_start) already refuses an unresolved target for this reason;
  # refusing here makes every away-mode entry path agree.
  if [ "$resolved" -eq 0 ]; then
    fm_afk_preflight_explain unresolved "$target" "$backend"
    return 1
  fi
  verdict=$(fm_afk_preflight_probe "$target" "$backend")
  if [ "$verdict" = empty ]; then
    echo "afk: preflight ok - supervisor composer at $target reads empty; wake path verified"
    return 0
  fi
  fm_afk_preflight_explain "$verdict" "$target" "$backend"
  return 1
}
