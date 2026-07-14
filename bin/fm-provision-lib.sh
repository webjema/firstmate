#!/usr/bin/env bash
# fm-provision-lib.sh - the contract for WAITING on `treehouse get` to hand a
# crewmate its worktree. Sourced by bin/fm-spawn.sh; sourced directly by
# tests/fm-provision.test.sh, which overrides the probes below.
#
# THE BUG THIS OWNS. Spawn used to poll the pane's cwd for a fixed 60 s and then
# die with "treehouse get did not enter a worktree within 60s". That bound was
# never defensible, and one opaque string covered three unrelated failures.
# Measured on this box (2026-07-14, treehouse v2.0.0, optiroq, WARM shared npm
# cache at ~/.npm-cache-shared):
#
#   warm slot (deps already present, post_create fast-exits)  ...........   2 s
#   COLD slot (fresh worktree + post_create npm install)      ........... 137 s
#
# 137 s is 2.3x the old 60 s cliff, so the FIRST spawn against a project whose
# pool has no warm slot - a fresh box, a new project, or an exhausted pool - was
# reliably killed by a timeout that named none of those causes. A cold npm cache
# is slower still. (bin/fm-pool-warm.sh exists to keep a warm slot ready so this
# wait normally costs the 2 s path; this lib is the floor for when it does not.)
#
# THE FIX IS NOT A BIGGER NUMBER. Raising 60 to 600 just fails later and still
# cannot tell "installing" from "wedged". Instead, every tick classifies the pane
# into one of three states, and only the middle one is allowed to consume time:
#
#   ENTERED   the pane's cwd left the project => the worktree is ours. Done.
#   BUSY      the pane's shell still has a live descendant (treehouse itself, the
#             post_create hook, npm, node). Something is running, so WAIT - this
#             is the cold-install case, and killing it is the old bug.
#   EXITED    no descendant and the cwd never moved => treehouse RETURNED without
#             handing over a worktree. It failed. Fail FAST (in seconds, not at a
#             timeout) and say WHY, read from the pane's own last words.
#
# A live descendant is the progress signal because it is structural, not scraped:
# an idle shell at a prompt has no children, and treehouse's whole pipeline
# (fetch, reset, clean, post_create) runs as one. Two bounds still apply so a
# genuinely wedged pane cannot hang a spawn forever:
#
#   STALL    BUSY but producing NOTHING - no new pane output and no churn in its
#            own process set - for this long => wedged (a hook prompting for
#            input, a hung network call). Default 300 s: an npm install spawns
#            and reaps children continuously, so real work never looks this dead.
#   TIMEOUT  an absolute ceiling even while visibly progressing. Default 900 s -
#            6.5x the measured cold install, leaving headroom for a cold npm
#            cache without waiting on a truly broken box forever.
#
# Failures are classified, never blended into one string (fm_provision_failure):
#   pool-exhausted  treehouse's own "max_trees" refusal - the pool is full of
#                   in-use or DIRTY slots. Actionable, and nothing like a timeout.
#   treehouse-error treehouse spoke and failed; its last line is relayed verbatim.
#   no-worktree     it exited silently without moving the cwd.
#   stalled         BUSY but dead-quiet past STALL.
#   timeout         still working at the ceiling; reports the elapsed seconds.
set -u

FM_PROVISION_TIMEOUT_DEFAULT=900   # absolute ceiling, seconds (see header)
FM_PROVISION_STALL_DEFAULT=300     # silent-while-busy ceiling, seconds
FM_PROVISION_TAIL_LINES=40         # pane lines read for a failure diagnosis
# AN IDLE PANE IS NEVER BELIEVED ON SIGHT. fm-spawn.sh sends `treehouse get` and
# calls straight into the wait, so the FIRST probe lands ~35ms later - before the
# pane's shell (still running its rc files) has even consumed the keystroke. It
# therefore has no children and looks exactly like a shell whose command exited.
# Measured on this box, window created and command sent with no grace, exactly as
# fm-spawn.sh does it: 10/10 first probes read `idle`. Honoring that verdict
# failed EVERY real spawn on tick one. So `idle` counts only once it has SETTLED
# (a startup grace) and then held for CONFIRM consecutive probes. A treehouse that
# really did fail stays idle forever and is still caught in seconds; a pane that
# was merely slow to start goes busy and never trips it.
FM_PROVISION_SETTLE_DEFAULT=5      # seconds before an idle pane may be believed at all
FM_PROVISION_IDLE_CONFIRM_DEFAULT=3  # consecutive idle probes required to call it exited

# --- probes -----------------------------------------------------------------
# The ONLY tmux-aware surface. Tests redefine these four after sourcing to drive
# fm_provision_wait against a scripted pane, so the decision logic below is
# tested with no tmux, no treehouse, and no multi-GB install.

# fm_provision_probe_path <target>: the pane's current working directory.
fm_provision_probe_path() {
  fm_backend_tmux_current_path "$1"
}

# fm_provision_probe_tail <target>: the pane's last lines. Read on every tick -
# it is half of the progress signature (fm_provision_progress_signature), not just
# the failure diagnosis. That is a pane capture per second for the life of the
# wait, which the architecture direction calls a last resort: it is here because
# the pane's OUTPUT is the only evidence that separates an install still churning
# from one wedged in silence, and no script writes that fact to a file.
fm_provision_probe_tail() {
  fm_backend_tmux_capture "$1" "$FM_PROVISION_TAIL_LINES"
}

# fm_provision_probe_descendants <target>: the pids running UNDER the pane's
# shell, newline-separated; empty when the shell sits idle at a prompt.
# One `ps` snapshot, then a breadth-first walk down from the pane's pid - so the
# npm/node tree deep under treehouse's hook counts as "running", not just a
# direct child.
fm_provision_probe_descendants() {  # <target>
  local target=$1 pane_pid snapshot frontier next found pid ppid
  pane_pid=$(fm_provision_probe_pane_pid "$target") || return 0
  [ -n "$pane_pid" ] || return 0
  snapshot=$(ps -eo pid=,ppid= 2>/dev/null) || return 0
  frontier=$pane_pid
  found=""
  while [ -n "$frontier" ]; do
    next=""
    while read -r pid ppid; do
      [ -n "${pid:-}" ] || continue
      case " $frontier " in
        *" $ppid "*) ;;
        *) continue ;;
      esac
      case " $found " in
        *" $pid "*) continue ;;
      esac
      found="$found $pid"
      next="$next $pid"
    done <<EOF
$snapshot
EOF
    frontier=$next
  done
  for pid in $found; do
    printf '%s\n' "$pid"
  done
}

# fm_provision_probe_pane_pid <target>: the pane's shell pid, or empty when it is
# unreadable or not a number.
fm_provision_probe_pane_pid() {  # <target>
  local pid
  pid=$(fm_backend_tmux_pane_pid "$1" 2>/dev/null) || return 0
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
    *) printf '%s' "$pid" ;;
  esac
}

# fm_provision_pane_state <target> [descendants]: busy | idle | unknown.
#   busy     a process is running under the pane's shell (treehouse, its hook, npm)
#   idle     the shell is at a prompt with nothing running => whatever we asked it
#            to run has EXITED
#   unknown  the pane's pid could not be read at all
# UNKNOWN IS NEVER TREATED AS IDLE. A false-idle reading would kill a spawn whose
# install is running perfectly well, so an unreadable probe must keep waiting and
# let the stall/timeout bounds decide. Same posture as fm_backend_agent_alive,
# which gates a respawn on a CONFIDENT `dead` only (bin/backends/tmux.sh).
# The caller passes the descendant list it already read, so the loop pays for one
# process-tree read per tick rather than two.
fm_provision_pane_state() {  # <target> [descendants]
  local target=$1 descendants=${2-}
  if [ -z "$(fm_provision_probe_pane_pid "$target")" ]; then
    printf 'unknown'
    return 0
  fi
  if [ $# -lt 2 ]; then
    descendants=$(fm_provision_probe_descendants "$target")
  fi
  if [ -z "$descendants" ]; then
    printf 'idle'
  else
    printf 'busy'
  fi
}

# --- decision logic ---------------------------------------------------------

# fm_provision_failure <kind> <tail>: the one owner of the operator-facing text
# for a failed acquisition. Each kind names a DIFFERENT real cause, because the
# operator's next move differs: a full pool needs slots reclaimed, a treehouse
# error needs its own message read, a stall needs the pane inspected.
fm_provision_failure() {  # <kind> <tail> [elapsed]
  local kind=$1 tail=${2:-} elapsed=${3:-} last
  # Quote the DIAGNOSTIC line, not merely the last one. By the time a failed
  # `treehouse get` is noticed the pane has returned to its prompt, so the last
  # non-empty line is the prompt itself - which told the operator nothing. Prefer
  # the last line that actually looks like a complaint, and fall back to the last
  # non-empty line only when nothing does.
  last=$(printf '%s\n' "$tail" | grep -Ei 'error|fatal|failed|max_trees|cannot|denied|refus' | tail -n 1)
  [ -n "$last" ] || last=$(printf '%s\n' "$tail" | grep -v '^[[:space:]]*$' | tail -n 1)
  last=$(printf '%s' "$last" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  case "$kind" in
    pool-exhausted)
      printf 'treehouse pool is FULL: every worktree is in use or dirty (max_trees reached), so no slot could be handed over. Reclaim a slot - "treehouse status" in the project lists them, and a DIRTY slot is skipped forever and is never reclaimed by "treehouse prune" either. treehouse said: %s' "$last"
      ;;
    treehouse-error)
      printf 'treehouse get FAILED (it exited without handing over a worktree). treehouse said: %s' "$last"
      ;;
    no-worktree)
      # "Nothing running under the pane's shell" is the evidence; do not overclaim
      # WHY. Almost always treehouse exited silently - but a shell blocked in a
      # BUILTIN (a bare `read` prompt) also has no child process, and reads
      # identically from outside. Say what was observed and point at the pane.
      printf 'treehouse get did not enter a worktree: nothing is running under the pane shell (treehouse exited without handing one over, or the pane is waiting at a prompt) and it printed no error. Inspect the pane'
      ;;
    stalled)
      printf 'treehouse get is STUCK: a process is still running but has produced no output for %ss (a hook waiting on input, or a hung network call). Last pane line: %s' "$elapsed" "$last"
      ;;
    timeout)
      printf 'treehouse get was still WARMING A COLD WORKSPACE after %ss and hit the ceiling. A cold dependency install is slow (measured: 137s for optiroq); if this project is legitimately slower, raise FM_SPAWN_WORKTREE_TIMEOUT. Last pane line: %s' "$elapsed" "$last"
      ;;
    *)
      printf 'treehouse get failed (%s)' "$kind"
      ;;
  esac
}

# fm_provision_classify_tail <tail>: which failure a dead pane's last words mean.
# Matches treehouse's OWN exhaustion wording ("max_trees"), verified against
# treehouse v2.0.0: "all %d worktrees are in use or dirty (max_trees = %d)".
fm_provision_classify_tail() {  # <tail>
  local tail=$1
  case "$tail" in
    *max_trees*) printf 'pool-exhausted' ;;
    *[Ee]rror*|*failed*|*[Ff]atal*) printf 'treehouse-error' ;;
    *) printf 'no-worktree' ;;
  esac
}

# fm_provision_wait <target> <project-real-path> [timeout] [stall]
# Blocks until the pane enters a worktree. On success prints the worktree path
# and returns 0. On failure prints a CLASSIFIED reason (fm_provision_failure) to
# stderr and returns 1. Callers get a path or a real diagnosis - never a bare
# "did not enter a worktree within 60s".
fm_provision_wait() {  # <target> <project-real-path> [timeout] [stall]
  local target=$1 proj_real=$2
  local timeout=${3:-${FM_SPAWN_WORKTREE_TIMEOUT:-$FM_PROVISION_TIMEOUT_DEFAULT}}
  local stall=${4:-${FM_SPAWN_WORKTREE_STALL:-$FM_PROVISION_STALL_DEFAULT}}
  local settle=${5:-${FM_SPAWN_WORKTREE_SETTLE:-$FM_PROVISION_SETTLE_DEFAULT}}
  local confirm=${6:-${FM_SPAWN_WORKTREE_IDLE_CONFIRM:-$FM_PROVISION_IDLE_CONFIRM_DEFAULT}}
  local elapsed=0 quiet=0 idle_streak=0 path sig prev_sig kind tail state descendants
  prev_sig=""

  while :; do
    # 1. ENTERED: the cwd left the project. The worktree is ours - the only
    #    success exit, and checked first so a successful get is never mistaken
    #    for the subshell-as-descendant case below.
    path=$(fm_provision_probe_path "$target" || true)
    if [ -n "$path" ] && [ "$(fm_provision_real_path "$path")" != "$proj_real" ]; then
      printf '%s\n' "$path"
      return 0
    fi

    # One process-tree read per tick, reused for BOTH the state verdict and the
    # progress signature below. Probing twice would run a second `ps` sweep every
    # second for the whole (possibly 900s) wait, for no new information.
    descendants=$(fm_provision_probe_descendants "$target")
    state=$(fm_provision_pane_state "$target" "$descendants")

    # 2. EXITED: the pane's shell is back at an idle prompt and the cwd never
    #    moved. treehouse gave up.
    #    But an idle reading is NOT believed on sight: for the first ~35ms of a
    #    real spawn the shell has not yet consumed the keystroke, so a pane that is
    #    about to work perfectly reads exactly like one whose command exited
    #    (10/10 measured - see the constants above). So idle must SETTLE and then
    #    HOLD for `confirm` consecutive probes before it counts. A genuinely failed
    #    treehouse stays idle and is still caught within seconds; a slow-starting
    #    pane goes busy and clears the streak. `unknown` never counts at all.
    if [ "$state" = idle ]; then
      idle_streak=$((idle_streak + 1))
      if [ "$elapsed" -ge "$settle" ] && [ "$idle_streak" -ge "$confirm" ]; then
        tail=$(fm_provision_probe_tail "$target" || true)
        kind=$(fm_provision_classify_tail "$tail")
        fm_provision_failure "$kind" "$tail" >&2
        return 1
      fi
    else
      idle_streak=0
    fi

    # 3. BUSY (or unreadable): something is running. This is the cold install, and
    #    it is allowed to take its time - bounded only by silence (stall) and the
    #    ceiling.
    sig=$(fm_provision_progress_signature "$target" "$descendants")
    if [ "$sig" != "$prev_sig" ]; then
      quiet=0
      prev_sig=$sig
    fi

    if [ "$stall" -gt 0 ] && [ "$quiet" -ge "$stall" ]; then
      tail=$(fm_provision_probe_tail "$target" || true)
      fm_provision_failure stalled "$tail" "$quiet" >&2
      return 1
    fi
    if [ "$timeout" -gt 0 ] && [ "$elapsed" -ge "$timeout" ]; then
      tail=$(fm_provision_probe_tail "$target" || true)
      fm_provision_failure timeout "$tail" "$elapsed" >&2
      return 1
    fi

    fm_provision_sleep 1
    elapsed=$((elapsed + 1))
    quiet=$((quiet + 1))
  done
}

# fm_provision_progress_signature <target> [descendants]: cheap evidence that the
# pane is still MOVING. Pane output plus the pane's own process set: an npm install
# spawns and reaps children constantly, so a real install churns this signature
# even between printed lines, while a wedged process holds it perfectly still.
# Takes the already-read descendant list so the loop reads the process tree once
# per tick.
fm_provision_progress_signature() {  # <target> [descendants]
  local target=$1 descendants=${2-}
  if [ $# -lt 2 ]; then
    descendants=$(fm_provision_probe_descendants "$target" 2>/dev/null)
  fi
  printf '%s|%s' \
    "$(fm_provision_probe_tail "$target" 2>/dev/null | cksum 2>/dev/null || true)" \
    "$(printf '%s' "$descendants" | cksum 2>/dev/null || true)"
}

# Seams the tests replace to run the loop with no real clock.
fm_provision_sleep() { sleep "$1"; }

fm_provision_real_path() {  # <path>
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
}
