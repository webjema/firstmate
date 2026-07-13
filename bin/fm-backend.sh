#!/usr/bin/env bash
# fm-backend.sh - meta helpers, selector resolution, and dispatch for firstmate's
# session-provider abstraction.
#
# tmux is the ONLY backend. The seam below survives because every caller
# (fm-send.sh, fm-peek.sh, fm-watch.sh, fm-spawn.sh, fm-teardown.sh,
# fm-crew-state.sh, fm-fleet-snapshot.sh, fm-supervise-daemon.sh) already speaks
# it: they name an operation plus a backend, and this file routes to
# bin/backends/tmux.sh. Keeping the dispatch shape means those call sites need no
# per-op rewrite, and it stays the single place a future backend would be added.
#
# Compatibility contract: a task's meta may omit `backend=`; every reader here
# treats that as `tmux` (fm_backend_of_meta), and fm-spawn.sh never writes a
# `backend=` line.
#
# Event-source framing: a backend's supervision surface is conceptually an EVENT
# SOURCE - it produces task events (status-changed, went-stale, exited) that map
# onto firstmate's signal/stale/check/heartbeat wake vocabulary. tmux has no
# native event push, so fm-watch.sh's poll loop over the pull primitives below
# (capture, list-live, busy-state via regex) IS the event-source implementation
# that synthesizes those events. The pull primitives also stay available on their
# own for on-demand reads (fm-peek.sh, fm-crew-state.sh).

FM_BACKEND_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_BACKEND_LIB_DIR="$(cd "$(dirname "$FM_BACKEND_SCRIPT")" && pwd)"
unset FM_BACKEND_SCRIPT
FM_BACKEND_DEFAULT_ROOT="$(cd "$FM_BACKEND_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# The verified backend set. tmux is the reference and only adapter
# (docs/tmux-backend.md).
FM_BACKEND_KNOWN="tmux"
FM_BACKEND_SPAWN="tmux"

# fm_backend_list_contains: whitespace-delimited membership without relying on
# shell word splitting. fm-backend.sh is normally sourced by bash scripts, but
# zsh diagnostics can source it too, so backend-name matching must stay portable.
fm_backend_list_contains() {  # <list> <name>
  local list=$1 name=$2
  case "$name" in
    *[[:space:]]*) return 1 ;;
  esac
  case " $list " in
    *" $name "*) return 0 ;;
  esac
  return 1
}

fm_backend_is_known() {  # <name>
  fm_backend_list_contains "$FM_BACKEND_KNOWN" "$1"
}

# fm_backend_name: the ACTIVE backend for a NEW spawn. Always tmux.
fm_backend_name() {
  printf 'tmux'
}

# fm_backend_validate: refuse an unknown backend LOUDLY. Silent on success.
fm_backend_validate() {  # <name>
  local name=$1
  if ! fm_backend_is_known "$name"; then
    echo "error: unknown backend '$name' (known: $FM_BACKEND_KNOWN)" >&2
    return 1
  fi
  return 0
}

fm_backend_validate_spawn() {  # <name>
  local name=$1
  fm_backend_validate "$name" || return 1
  fm_backend_list_contains "$FM_BACKEND_SPAWN" "$name" && return 0
  echo "error: backend '$name' does not support task spawning yet (spawn-supported: $FM_BACKEND_SPAWN)" >&2
  return 1
}

# fm_backend_required_tools: the backend-SPECIFIC CLI tools a firstmate home
# requires, beyond firstmate's universal toolchain (owned by
# docs/configuration.md "Toolchain" and bootstrap's COMMON list): the session
# provider itself plus the treehouse worktree provider. Prints a single
# space-separated line and returns 0 for a known backend; returns 1 and prints
# nothing otherwise.
fm_backend_required_tools() {  # <backend>
  case "$1" in
    tmux) printf '%s' 'tmux treehouse' ;;
    *) return 1 ;;
  esac
}

fm_backend_required_tool_available() {  # <backend> <tool>
  local backend=$1 tool=$2 required
  required=$(fm_backend_required_tools "$backend") || return 1
  fm_backend_list_contains "$required" "$tool" || return 1
  command -v "$tool" >/dev/null 2>&1
}

# fm_meta_get: the LAST value of `key=` in <meta-file>, or empty (never
# errors) if the file or key is absent. Mirrors the ad hoc `grep '^key=' |
# tail -1 | cut -d= -f2-` snippet every fm-*.sh script used to repeat inline.
fm_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# fm_backend_of_meta: the backend recorded in <meta-file>, defaulting to `tmux`
# when the field is absent - which it always is on a freshly spawned task.
fm_backend_of_meta() {  # <meta-file>
  local v
  v=$(fm_meta_get "$1" backend)
  printf '%s' "${v:-tmux}"
}

fm_backend_target_of_meta() {  # <meta-file>
  local meta=$1 window
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] && printf '%s' "$window"
}

fm_backend_meta_for_window() {  # <target> <state-dir>
  local target=$1 state=$2 meta window
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] && [ "$window" = "$target" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_backend_task_id_for_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  case "$raw" in
    *:*) return 1 ;;
  esac
  if [ -f "$state/$raw.meta" ]; then
    printf '%s' "$raw"
    return 0
  fi
  case "$raw" in
    fm-*)
      id=${raw#fm-}
      [ -f "$state/$id.meta" ] || return 1
      printf '%s' "$id"
      return 0
      ;;
  esac
  return 1
}

fm_backend_meta_for_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  id=$(fm_backend_task_id_for_selector "$raw" "$state") || return 1
  printf '%s/%s.meta' "$state" "$id"
}

fm_backend_of_selector() {  # <raw-target> <resolved-target> <state-dir>
  local raw=$1 resolved=$2 state=$3 meta
  meta=$(fm_backend_meta_for_selector "$raw" "$state" 2>/dev/null || true)
  [ -n "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
  if [ -n "$resolved" ]; then
    meta=$(fm_backend_meta_for_window "$resolved" "$state" 2>/dev/null || true)
    [ -n "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
  fi
  printf 'tmux'
}

fm_backend_expected_label_of_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  id=$(fm_backend_task_id_for_selector "$raw" "$state" 2>/dev/null || true)
  [ -n "$id" ] && printf 'fm-%s' "$id"
  return 0
}

# fm_backend_source: source the named backend's adapter file, once per shell.
fm_backend_source() {  # <name>
  local name=$1
  fm_backend_validate "$name" || return 1
  case "$name" in
    tmux)
      if [ -z "${_FM_BACKEND_TMUX_SOURCED:-}" ]; then
        # shellcheck source=bin/backends/tmux.sh
        . "$FM_BACKEND_LIB_DIR/backends/tmux.sh" || return 1
        _FM_BACKEND_TMUX_SOURCED=1
      fi
      ;;
  esac
}

# fm_backend_resolve_selector: resolve a raw fm-send.sh/fm-peek.sh style
# selector to a live session-provider target. Four forms, in order:
#   target with ":"   used as-is (the escape hatch for a window/pane outside
#                      this firstmate home) - a literal string.
#   exact task id      routed through <state-dir>/<id>.meta's `window=` -
#                      a stored value, NOT re-verified against a live backend
#                      inventory (tmux window names can be trusted from meta
#                      without a live re-check).
#   "fm-<id>"          legacy task window label fallback routed through
#                      <state-dir>/<id>.meta when no exact
#                      <state-dir>/fm-<id>.meta exists.
#   anything else      first matched against recorded `window=` metadata, then
#                      treated as an ad hoc bare window name and resolved by
#                      searching the tmux live inventory.
fm_backend_resolve_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 meta window
  case "$raw" in
    *:*)
      printf '%s' "$raw"
      return 0
      ;;
  esac
  meta=$(fm_backend_meta_for_selector "$raw" "$state" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    window=$(fm_backend_target_of_meta "$meta")
    [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
    printf '%s' "$window"
    return 0
  fi
  case "$raw" in
    fm-*)
      echo "error: no metadata for $raw in $state; pass session:window to target a window outside this firstmate home" >&2
      return 1
      ;;
    *)
      meta=$(fm_backend_meta_for_window "$raw" "$state" 2>/dev/null || true)
      if [ -n "$meta" ]; then
        window=$(fm_backend_target_of_meta "$meta")
        [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
        printf '%s' "$window"
        return 0
      fi
      fm_backend_source tmux || return 1
      fm_backend_tmux_resolve_bare_selector "$raw"
      ;;
  esac
}

# --- generic per-op dispatch -------------------------------------------------
#
# Thin case-dispatch wrappers so a caller names an operation and a backend
# rather than hand-writing `case "$backend" in tmux) fm_backend_tmux_x ;; esac`
# at every call site.

# fm_backend_capture: bounded plain-text session capture.
fm_backend_capture() {  # <backend> <target> <lines> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_capture "$@" ;;
    *) echo "error: no capture implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# fm_backend_send_key: one backend-supported named special key.
fm_backend_send_key() {  # <backend> <target> <key> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_send_key "$@" ;;
    *) echo "error: no send-key implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# fm_backend_send_text_submit: type text once, then submit and verify,
# retrying only the submission (never retyping). Echoes the verdict
# (empty|pending|unknown|send-failed).
fm_backend_send_text_submit() {  # <backend> <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_send_text_submit "$@" ;;
    *) echo "error: no send-text implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# fm_backend_kill: remove the task's session endpoint (best-effort; a
# nonexistent/already-gone target is not an error - callers already swallow
# failures here exactly as the inline `tmux kill-window ... || true` did).
fm_backend_kill() {  # <backend> <target>
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) fm_backend_tmux_kill "$@" ;;
    *) echo "error: no kill implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# fm_backend_busy_state: semantic busy/idle/unknown for a backend that exposes
# native agent-state. tmux has no such primitive and reports unknown, so callers
# own the fallback policy: fm-watch.sh uses unknown as the cue for its pane-hash
# + FM_BUSY_REGEX detection, and fm-crew-state.sh does the same.
fm_backend_busy_state() {  # <backend> <target>
  printf 'unknown'
}

# fm_backend_composer_state: classify the composer/input row of <target> as
# empty|pending|unknown for callers that need a pre-submit pending-input guard.
# Exposed generically so a caller other than the send path (the away-mode
# daemon's supervisor-pane pending-input guard, bin/fm-supervise-daemon.sh) can
# ask the same question without duplicating composer-reading logic.
fm_backend_composer_state() {  # <backend> <target> -> empty|pending|unknown
  local backend=$1
  shift
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    tmux) fm_tmux_composer_state "$@" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_target_exists: cheap, READ-ONLY existence check - does the recorded
# TARGET endpoint still exist? Never starts a server or session. A gone tmux
# window simply fails, which IS "does not exist" for this purpose.
# Mirrors fm-crew-state.sh's pane_readable check; exists here as one shared
# primitive so callers that only need a fast alive/dead read (recovery digests,
# the session-start fleet digest) do not re-derive it inline.
fm_backend_target_exists() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2
  case "$backend" in
    tmux)
      tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

# fm_backend_agent_alive: CONFIDENT liveness of a live harness-agent PROCESS
# under <target>, distinct from fm_backend_target_exists's pane-PRESENCE-only
# check above. A secondmate agent that has exited leaves its backend endpoint
# alive as a bare shell; fm_backend_target_exists reports that shell as
# "alive" because the pane itself still exists, which is exactly the gap
# bin/fm-bootstrap.sh's session-start secondmate-liveness sweep exists to
# close (AGENTS.md "Session start"). Prints one of:
#   alive   - a real agent process is confirmed running.
#   dead    - CONFIDENTLY not an agent: a bare shell.
#   unknown - anything ambiguous, unreadable, or unverified.
# See docs/tmux-backend.md "Agent liveness probe" for the empirical basis.
# Callers must treat unknown exactly like an unreadable target: NEVER license
# an action from it alone - the secondmate-liveness sweep gates a respawn on
# `dead` only, precisely so a momentary read glitch can never duplicate a
# live supervisor.
fm_backend_agent_alive() {  # <backend> <target>
  local backend=$1 target=$2
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    tmux) fm_backend_tmux_agent_alive "$target" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_remove_worktree / fm_backend_worktree_path: the worktree-provider
# surface, for a backend that owns the task worktree instead of treehouse. tmux
# is a session provider only, so both always refuse. They stay defined because
# bin/fm-teardown.sh calls them behind its own backend guard.
fm_backend_remove_worktree() {  # <backend> <worktree-id>
  echo "error: backend '$1' does not own task worktrees" >&2
  return 1
}

fm_backend_worktree_path() {  # <backend> <worktree-id>
  echo "error: backend '$1' does not own task worktrees" >&2
  return 1
}

# --- native event push -------------------------------------------------------
#
# No backend implements a native transition push stream: tmux has none, so
# fm_backend_has_push is always false and fm-watch.sh runs its poll loop, the
# permanent fail-closed supervision path. The seam stays so a future
# push-capable backend can be added without touching the watcher, and so callers
# that already dispatch through it (bin/fm-teardown.sh's per-task transition
# cleanup) keep working unchanged.

# fm_backend_has_push: 0 if <backend> exposes a native transition push stream.
fm_backend_has_push() {  # <backend>
  return 1
}

# fm_backend_events_capable: 0 if <backend>'s push path is usable for <session>
# right now. Never, with no push-capable backend.
fm_backend_events_capable() {  # <backend> <session>
  return 1
}

# fm_backend_wait_transition: bounded wait for a fresh actionable transition.
# Returns 2 ("event path unusable") so the caller sleeps its own budget.
fm_backend_wait_transition() {  # <backend> <session> <timeout_secs> <state_dir> <window...>
  return 2
}

fm_backend_commit_transition() {  # <backend> <state_dir> <session> <record>
  return 1
}

fm_backend_clear_transition() {  # <backend> <state_dir> <window>
  return 0
}
