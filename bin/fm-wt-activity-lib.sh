#!/usr/bin/env bash
# Worktree-activity probe: THE ONE OWNER of the "is this crew actually changing
# the work?" snapshot and of the rule for what counts as progress between two
# snapshots.
#
# The supervision path used to see only the SCREEN (a pane hash) and the crew's
# own self-reported status lines. Both lie in opposite directions: a crew that
# commits steadily but says nothing for five minutes looks identical to a wedged
# one, and a crew spinning on a redraw loop without touching a file looks alive
# because its pane keeps changing. The worktree is the ground truth neither can
# fake - it is where the work either lands or does not.
#
# A snapshot is ONE line of "<field>=<value>" tokens, safe to embed in a wake
# payload or a turn-end marker body:
#
#   head=<sha|none> idx=<epoch> edit=<epoch> dirty=<n|?>
#
#   head=   HEAD's commit sha (short), or `none` for an unborn/unreadable HEAD.
#           Moves on every commit, so it is the strongest positive signal.
#   idx=    mtime of .git/index. Advances on stage/commit; O(1) and always taken.
#   edit=   newest mtime among tracked files modified vs HEAD - the crew editing
#           files without committing. 0 when unknown or when the status leg is
#           skipped (see the cost bound below).
#   dirty=  count of modified tracked files, or `?` when the status leg is skipped.
#
# COST BOUND. This runs on every watcher poll for every in-flight task, so the
# cheap legs (head, idx) are two file reads and always run. The `edit`/`dirty`
# leg needs `git status`, whose cost scales with the tracked-file count, so it is
# skipped on a repo above FM_WT_PROBE_MAX_FILES (default 20000). The tracked-file
# count is measured ONCE per worktree and cached in <state>/.wt-size-<task>, so the
# bound itself costs nothing after the first poll. A skipped leg is reported
# honestly as `edit=0 dirty=?`, never as "no changes": the caller then falls back
# to head/idx, which still catch every commit. FM_WT_PROBE=0 disables the probe
# entirely and every snapshot is empty.

# 0 if the probe is enabled at all.
wt_probe_enabled() {
  [ "${FM_WT_PROBE:-1}" != 0 ]
}

# Reduce a NUL-separated path list on stdin to "<newest-mtime> <count>".
# NUL-separated (git -z) so a path with a newline or a quote in it is still read
# exactly, and reduced INSIDE the pipe: a command substitution around the raw list
# would silently drop the NULs (bash strips them), which is how an early cut of
# this probe lost the only modified file and reported an editing crew as idle.
_wt_reduce_changed() {  # <worktree>
  local wt=$1 p newest=0 n=0 m
  while IFS= read -r -d '' p; do
    [ -n "$p" ] || continue
    n=$((n + 1))
    m=$(stat -c %Y "$wt/$p" 2>/dev/null || stat -f %m "$wt/$p" 2>/dev/null || echo 0)
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    [ "$m" -gt "$newest" ] && newest=$m
  done
  printf '%s %s' "$newest" "$n"
}

_wt_mtime_of() {  # <path>
  local m
  m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
  case "$m" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$m" ;; esac
}

# Is this worktree small enough for the `git status` leg? Measured once, cached.
_wt_status_leg_ok() {  # <worktree> <state> <task>
  local wt=$1 state=${2:-} task=${3:-} cap cache n
  cap=${FM_WT_PROBE_MAX_FILES:-20000}
  cache=""
  [ -n "$state" ] && [ -n "$task" ] && cache="$state/.wt-size-$task"
  if [ -n "$cache" ] && [ -f "$cache" ]; then
    n=$(cat "$cache" 2>/dev/null || echo 0)
  else
    n=$(git -C "$wt" ls-files 2>/dev/null | wc -l | tr -d ' ')
    [ -n "$cache" ] && printf '%s' "$n" > "$cache" 2>/dev/null
  fi
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -le "$cap" ]
}

# Print the one-line snapshot for a worktree. Never fails, never blocks: an
# unreadable or missing worktree prints nothing, and the caller treats an empty
# snapshot as "no evidence either way", never as "no progress".
wt_activity_snapshot() {  # <worktree> [<state> <task>]
  local wt=$1 state=${2:-} task=${3:-} head idx edit=0 dirty='?' changed
  wt_probe_enabled || return 0
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || return 0

  head=$(git -C "$wt" rev-parse --short HEAD 2>/dev/null || true)
  [ -n "$head" ] || head=none
  idx=$(_wt_mtime_of "$(git -C "$wt" rev-parse --git-path index 2>/dev/null)")

  # One `git diff --name-only HEAD` serves both remaining fields: the modified
  # tracked files are exactly what we count (dirty) and whose mtimes we max (edit).
  if _wt_status_leg_ok "$wt" "$state" "$task"; then
    changed=$(git -C "$wt" diff --name-only -z HEAD 2>/dev/null | _wt_reduce_changed "$wt")
    edit=${changed%% *}
    dirty=${changed##* }
    case "$edit" in ''|*[!0-9]*) edit=0 ;; esac
    case "$dirty" in ''|*[!0-9]*) dirty=0 ;; esac
  fi

  printf 'head=%s idx=%s edit=%s dirty=%s' "$head" "$idx" "$edit" "$dirty"
}

# Read one field out of a snapshot (or out of any line of "k=v" tokens, such as a
# turn-end marker body, which carries the snapshot plus a turn counter).
wt_field() {  # <line> <field>
  local line=$1 key=$2 tok
  for tok in $line; do
    case "$tok" in "$key"=*) printf '%s' "${tok#"$key"=}"; return 0 ;; esac
  done
  return 1
}

# 0 when <new> shows the crew ACTUALLY MOVED THE WORK since <old>: HEAD advanced,
# the index advanced, or a tracked file was edited more recently. Absence of
# evidence is never progress - an empty snapshot on either side returns 1, so a
# caller that cannot probe falls back to its pane/status evidence rather than
# silently absorbing a wedged crew.
wt_activity_advanced() {  # <old-snapshot> <new-snapshot>
  local old=$1 new=$2 o n f
  [ -n "$old" ] && [ -n "$new" ] || return 1

  o=$(wt_field "$old" head || true); n=$(wt_field "$new" head || true)
  [ -n "$n" ] && [ "$n" != none ] && [ "$n" != "$o" ] && return 0

  for f in idx edit; do
    o=$(wt_field "$old" "$f" || echo 0); n=$(wt_field "$new" "$f" || echo 0)
    case "$o$n" in *[!0-9]*) continue ;; esac
    [ "$n" -gt "$o" ] && return 0
  done
  return 1
}
