#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: fm-bootstrap.sh
#          Detect: prints one line per problem or capability fact and exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)", "NEEDS_GH_AUTH",
#                 "CREW_HARNESS_OVERRIDE: <name>",
#                 "FLEET_SYNC: <repo>: skipped|recovered|STUCK: <detail>",
#                 "TASKS_AXI: available", "TANGLE: <remediation>",
#                 "POOL_SLOT: <project>: <unusable slot + the exact reclaim command>",
#                 "POOL_BUDGET: <project>: <why warming stopped>",
#                 "SECONDMATE_SYNC: secondmate <id>: skipped: <reason>",
#                 "NUDGE_SECONDMATES: fm-<id>...",
#                 "SECONDMATE_LIVENESS: secondmate <id>: already-live|respawned|skipped: <reason>|respawn failed: <reason>".
#          A NUDGE_SECONDMATES line lists the RUNNING secondmate task selectors
#          (fm-<id>) whose worktree was fast-forwarded to firstmate's own
#          current default-branch commit (a purely LOCAL fast-forward, never an
#          origin fetch) AND whose instruction surface (AGENTS.md, bin/, or
#          .agents/skills/) actually changed; firstmate nudges each via
#          bin/fm-send.sh fm-<id> so meta resolves the current backend target
#          even when the same bootstrap run also respawned the secondmate.
#          Already-current or no-instruction-change homes are silently left alone.
#          The secondmate sweep also propagates declared inheritable local config
#          into each validated live secondmate home.
#          SECONDMATE_SYNC lines report actionable skipped local-HEAD syncs or
#          config-inheritance failures for live secondmate homes; no-op/current
#          and successful updates stay quiet.
#          SECONDMATE_LIVENESS lines report every live secondmate's deeper
#          agent-liveness verdict (bin/fm-backend.sh's fm_backend_agent_alive,
#          distinct from the endpoint pane-presence check): already-live is a
#          no-op, respawned means a confirmed-dead endpoint (a bare shell left
#          behind by an exited secondmate agent) was killed and relaunched via
#          bin/fm-spawn.sh --secondmate, and skipped means the probe could not
#          confidently classify the endpoint (never acted on - a false-dead
#          reading would spin up a duplicate agent). Session-start scope only;
#          see AGENTS.md "Session start" and docs/tmux-backend.md
#          "Agent liveness probe" for the empirical basis.
#          A TANGLE line means the firstmate primary checkout (FM_ROOT) is stranded
#          on a feature branch instead of its default branch - a crewmate's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          POOL_SLOT / POOL_BUDGET lines come from bin/fm-pool-status.sh, whose
#          header owns their full format and the reasoning behind them. They are
#          read-only reports of treehouse pool slots that can no longer be handed
#          out (dirty, stale-leased, orphaned) and of a warm that a ceiling
#          stopped; bootstrap NEVER reclaims a slot, because a dirty one may hold
#          a dead crew's unlanded work.
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support.
#          tasks-axi is a required bootstrap tool (same class as lavish-axi) and is
#          version and feature gated (0.1.1+ with update --archive-body and
#          mv [<id>...]); an installed but incompatible build reports MISSING. When
#          config/backlog-backend is not manual and tasks-axi is compatible,
#          bootstrap prints TASKS_AXI: available.
#          Fleet sync fetches, fast-forwards safe default-branch states, reports
#          recovered and STUCK clone drift, and prunes gone local branches; it is
#          bounded by FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT when it is a non-empty
#          numeric override, while non-numeric values fall back to 20s.
#          When the override is unset or blank, the timeout is
#          max(20, 5 + 3 * origin-backed project clone count). A timed-out
#          refresh relays any completed fm-fleet-sync.sh output before the
#          aggregate timeout skip line with timeout and elapsed seconds.
#          Set FM_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#          Set FM_BOOTSTRAP_DETECT_ONLY=1 to skip the three MUTATING sweeps
#          (secondmate_sync, secondmate_liveness_sweep, fleet_sync) while still
#          printing every read-only detect line above; the TANGLE line switches to
#          advisory-only wording with no checkout command. Used by
#          fm-session-start.sh's read-only path when another live session holds
#          the fleet lock, so a second concurrent session never race-mutates
#          secondmate homes, project clones, or repair instructions. Unset/0 (the
#          default) runs every sweep exactly as before - this flag is purely
#          additive.
#        fm-bootstrap.sh install <tool>...
#          Install the named tools (only ones the user approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

fleet_sync_origin_backed_project_count() {
  local count proj
  count=0
  [ -d "$PROJECTS" ] || { echo 0; return 0; }
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$proj" remote get-url origin >/dev/null 2>&1 || continue
    count=$((count + 1))
  done
  echo "$count"
}

fleet_sync_bootstrap_timeout() {
  local count timeout
  if [ -n "${FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-}" ]; then
    case "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" in
      *[!0-9]*) echo 20 ;;
      *) echo "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" ;;
    esac
    return 0
  fi

  count=$(fleet_sync_origin_backed_project_count)
  timeout=$((5 + (3 * count)))
  [ "$timeout" -ge 20 ] || timeout=20
  echo "$timeout"
}

fleet_sync_relay_filtered_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
      *': STUCK:'*) echo "FLEET_SYNC: $line" ;;
      *': recovered:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
}

fleet_sync_relay_all_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "FLEET_SYNC: $line"
  done < "$tmp"
}

fleet_sync() {
  [ -x "$FM_ROOT/bin/fm-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  timeout=$(fleet_sync_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$FM_ROOT/bin/fm-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fleet_sync_relay_all_output "$tmp"
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  fleet_sync_relay_filtered_output "$tmp"
  rm -f "$tmp"
}

secondmate_sync() {
  # Local-HEAD secondmate sync: fast-forward every LIVE secondmate home
  # to the primary checkout's current default-branch commit. Purely LOCAL - no
  # fetch, no origin dependency: a linked-worktree home already holds the primary's
  # commit (fm-ff-lib.sh), while a standalone clone without it is skipped until
  # /updatefirstmate refreshes it from origin. Emits NUDGE_SECONDMATES:
  # only for RUNNING secondmates whose instruction surface (AGENTS.md, bin/, or
  # .agents/skills/) actually changed, so a secondmate already on the primary's
  # version is never disturbed (AGENTS.md bootstrap + supervision). Mirrors
  # fm-update's nudge-secondmates: report so firstmate can live-converge the
  # listed fm-<id> selectors.
  [ -d "$STATE" ] || return 0
  local primary_head
  if ! primary_head=$(primary_head_commit "$FM_ROOT"); then
    local meta id
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      grep -q '^kind=secondmate' "$meta" 2>/dev/null || continue
      id=$(basename "$meta" .meta)
      echo "SECONDMATE_SYNC: secondmate $id: skipped: primary default-branch commit cannot be resolved"
    done
    return 0
  fi
  FF_NUDGE_WINDOWS=""
  FF_SEEN_HOMES=""
  local tmp line
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-secondmate-sync.XXXXXX" 2>/dev/null) || return 0
  sweep_live_secondmate_metas "$STATE" "$primary_head" yes >"$tmp"
  while IFS= read -r line; do
    case "$line" in
      secondmate\ *': skipped:'*) echo "SECONDMATE_SYNC: $line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  # Inheritable-config propagation: push the primary's declared LOCAL config
  # into every VALIDATED live secondmate home swept
  # above (FF_SEEN_HOMES is exactly that set). config/ is gitignored, so this is a
  # separate copy from the tracked-files fast-forward; primary-authoritative, so
  # it runs whether or not the home's tracked files advanced, keeping the fleet
  # converged on the primary. The propagation helper stays silent on success; a
  # primary with no inheritable config set and no downstream copy is a no-op.
  local id home home_real propagated_homes
  propagated_homes=""
  while IFS='|' read -r id home _window _meta; do
    validate_secondmate_home "$id" "$home" || continue
    home_real="$VALIDATED_HOME"
    case " $FF_SEEN_HOMES " in
      *" $home_real "*) ;;
      *) continue ;;
    esac
    case " $propagated_homes " in
      *" $home_real "*) continue ;;
    esac
    propagated_homes="$propagated_homes $home_real"
    if ! propagate_inheritable_config "$CONFIG" "$home_real/config"; then
      echo "SECONDMATE_SYNC: secondmate $id: skipped: config inheritance failed"
    fi
  done < <(live_secondmate_meta_records "$STATE" "$FM_HOME/data/secondmates.md")
  [ -n "$FF_NUDGE_WINDOWS" ] && echo "NUDGE_SECONDMATES:$FF_NUDGE_WINDOWS"
  return 0
}

secondmate_liveness_sweep() {
  # Idempotent secondmate liveness guarantee - SESSION START ONLY. A
  # secondmate agent that has exited leaves its backend endpoint alive as a
  # bare shell; the session-start digest's "endpoint: alive" read
  # (fm_backend_target_exists, pane-PRESENCE only) reports that shell as
  # alive, so recovery never respawns it, and the watcher deliberately exempts
  # secondmates from stale-pane detection (an idle secondmate pane is healthy
  # by design). Evidence 2026-07-07: every secondmate in this fleet was found
  # as a dead zsh shell, invisible to every existing check. This sweep closes
  # the gap deterministically: for every LIVE secondmate meta (kind=secondmate
  # with a recorded window=), run the deeper fm_backend_agent_alive probe
  # (bin/fm-backend.sh) and act only on a CONFIDENT verdict:
  #   alive   - no-op.
  #   dead    - kill the stale endpoint first (best-effort; the tmux adapter
  #             refuses to create a same-named window over a live one) then
  #             respawn via the existing recovery path (bin/fm-spawn.sh <id>
  #             --secondmate; secondmate-provisioning).
  #   unknown - NEVER acted on. A false-dead reading would spin up a DUPLICATE
  #             agent (two supervisors in one home); a false-alive reading
  #             merely leaves today's bug unfixed for one more sweep. The
  #             worse direction is guarded by never treating anything less
  #             than a confident dead reading as license to respawn.
  # A meta with no recorded window= at all is left to the existing "meta with
  # no window" recovery path (AGENTS.md section 5 / secondmate-provisioning);
  # there is no endpoint here for this probe to read.
  # Naturally scoped to the primary: a secondmate's own state/ never holds
  # kind=secondmate metas (secondmates never spawn secondmates), so this
  # sweep is a silent no-op there, exactly like secondmate_sync above.
  # Scope: session start (reboot/restart) only. A secondmate dying
  # MID-SESSION is a harder follow-on needing a periodic liveness beacon -
  # explicitly out of scope here.
  [ -d "$STATE" ] || return 0
  local meta id window harness backend target verdict out
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] || continue
    harness=$(fm_meta_get "$meta" harness)
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || target="$window"
    verdict=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null) || verdict="unknown"
    case "$harness" in
      claude|codex|opencode|pi|grok) ;;
      *) [ "$verdict" = dead ] && verdict=unknown ;;
    esac
    case "$verdict" in
      alive)
        echo "SECONDMATE_LIVENESS: secondmate $id: already-live"
        ;;
      dead)
        fm_backend_kill "$backend" "$target" 2>/dev/null || true
        if out=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1); then
          echo "SECONDMATE_LIVENESS: secondmate $id: respawned"
        else
          echo "SECONDMATE_LIVENESS: secondmate $id: respawn failed: $(first_line "$out")"
        fi
        ;;
      *)
        echo "SECONDMATE_LIVENESS: secondmate $id: skipped: liveness probe inconclusive (backend=$backend)"
        ;;
    esac
  done
  return 0
}

install_cmd() {
  case "$1" in
    tmux|node|git|gh|curl|jq) echo "brew install $1  # or the platform's package manager" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi|lavish-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    tasks-axi) echo "npm install -g $1" ;;
    *) return 1 ;;
  esac
}

missing_tool_diagnostic() {
  local tool=$1
  echo "MISSING: $tool (install: $(install_cmd "$tool"))"
}

# Required tools: firstmate's universal toolchain (docs/configuration.md
# "Toolchain") plus the backend delta owned by fm_backend_required_tools
# (bin/fm-backend.sh) - tmux itself and the treehouse worktree provider.
COMMON_TOOLS="node git gh gh-axi chrome-devtools-axi lavish-axi tasks-axi"
BACKEND=$(fm_backend_name)
BACKEND_TOOLS=$(fm_backend_required_tools "$BACKEND")
TOOLS="$BACKEND_TOOLS $COMMON_TOOLS"

treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: fm-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    cmd=$(install_cmd "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

for t in $BACKEND_TOOLS; do
  fm_backend_required_tool_available "$BACKEND" "$t" \
    || missing_tool_diagnostic "$t"
done
for t in $COMMON_TOOLS; do
  command -v "$t" >/dev/null || missing_tool_diagnostic "$t"
done
if fm_backend_list_contains "$TOOLS" treehouse \
  && command -v treehouse >/dev/null 2>&1 && ! treehouse_supports_lease; then
  echo "MISSING: treehouse (install: $(install_cmd treehouse))"
fi
if command -v tasks-axi >/dev/null 2>&1 && ! fm_tasks_axi_compatible; then
  echo "MISSING: tasks-axi (install: $(install_cmd tasks-axi))"
fi
gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
# Worktree-tangle check: the firstmate primary checkout (FM_ROOT) must sit on its
# default branch, not a feature branch (see fm-tangle-lib.sh). Scoped to the
# primary only; detached-HEAD worktrees and secondmate homes never trip it.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" 2>/dev/null || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
    echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
  else
    echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
  fi
fi
crew=
[ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
[ -n "$crew" ] && [ "$crew" != "default" ] && echo "CREW_HARNESS_OVERRIDE: $crew"
if ! fm_backlog_backend_manual "$CONFIG" && fm_tasks_axi_compatible; then
  echo "TASKS_AXI: available"
fi
# Pool health: a crew that dies mid-task (three box reboots did this on
# 2026-07-14) leaves its treehouse slot DIRTY, and treehouse then skips that slot
# forever while prune refuses to reclaim it - so the pool silently shrinks until a
# spawn fails. This is READ-ONLY detection: it reports unusable slots and never
# discards one, because a dirty slot may hold the dead crew's unlanded work.
# Runs in detect-only mode too, for exactly that reason.
if [ -x "$FM_ROOT/bin/fm-pool-status.sh" ] && command -v treehouse >/dev/null 2>&1; then
  "$FM_ROOT/bin/fm-pool-status.sh" 2>/dev/null || true
fi
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  secondmate_sync
  secondmate_liveness_sweep
  fleet_sync
fi
exit 0
