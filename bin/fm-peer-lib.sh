#!/usr/bin/env bash
# fm-peer-lib.sh - what one firstmate instance knows about the OTHER instances
# sharing this host. Sourced by bin/fm-fleet-sync.sh, bin/fm-update.sh,
# bin/fm-lock.sh, bin/fm-spawn.sh and bin/fm-teardown.sh.
#
# It exists for the supported arrangement in docs/configuration.md: one checkout,
# one projects/ clone per repository and one worktree pool per host, with each
# instance carrying only its own state/, data/ and config/ in a bare $FM_HOME.
# Sharing turns two things that were private into contended resources, and this
# library owns both.
#
# 1. THE PER-CLONE WRITE LOCK, and it is for LIVENESS, not for correctness.
#    Measured 2026-08-16: two homes running fleet sync against one shared clone,
#    16 runs, zero integrity failures - git's own index.lock serialises them and
#    the loser prints "skipped: fast-forward failed" and does nothing. So the
#    clone never corrupts; it goes STALE, because the loser fetched a ref the
#    winner's merge did not land and then gave up instead of re-reading. The lock
#    therefore makes the loser WAIT and then do its work, on a fetch it takes
#    after the winner. A lock that made it refuse faster would solve nothing.
#    flock, so the kernel releases it when the holder dies - crash, SIGKILL,
#    reboot - which is the same reason bin/fm-pool-lib.sh prefers it for the pool.
#    THE BOUND IS A BACKSTOP AGAINST A WEDGED HOLDER, not a fit to any caller's
#    budget: a holder is one fetch plus one fast-forward, so a wait past a minute
#    means something is stuck, and no caller should park on it. What protects
#    bin/fm-bootstrap.sh's own timeout is not the bound but the two-pass sweep -
#    bin/fm-fleet-sync.sh tries every clone without waiting first, so a contended
#    clone can never starve the uncontended ones; only the retry pass waits.
#    THE LOCKED COMMAND DOES NOT INHERIT THE LOCK FD. A body that leaves anything
#    running in the background - git's own detached `gc --auto` is the one on the
#    path here - would otherwise keep the clone locked long after the runner
#    returned, because the child inherits the open descriptor the flock lives on.
#    NOTHING IS WRITTEN INSIDE THE CLONE. AGENTS.md rail 1 is that firstmate never
#    writes to projects/, and a lock file under .git would break it for no gain,
#    so the locks live in the cache dir below, keyed by the clone's PHYSICAL path -
#    which is what makes two homes pointing at one shared clone contend.
#
# 2. THE LIVE-PEER SESSION REGISTRY, which answers "is another instance running
#    from MY checkout mid-turn right now". bin/fm-update.sh needs it because a
#    self-update fast-forwards $FM_ROOT, and under sharing that is the checkout
#    every peer is running from: one instance's update swaps bin/ beneath them.
#    THE CHECKOUT IS PART OF THE ENTRY, not an assumption. Every secondmate home
#    is its own full checkout with its own bin/, and its charter has it run
#    bin/fm-session-start.sh - so it registers here and stays registered for as
#    long as it idles. Matching on liveness alone made /updatefirstmate refuse
#    for as long as any secondmate was up, which is a refusal that never clears
#    against the one command whose job includes updating that secondmate.
#    A peer is discoverable only if it says so, because nothing else ties the
#    instances together - each home knows its checkout, the checkout knows no
#    homes. So bin/fm-lock.sh registers each session as it acquires its home lock.
#    The registry is VOLATILE by design and lives in the cache dir, never in
#    $FM_HOME: an entry is a pid-backed claim, meaningless after a reboot, and
#    liveness is always re-derived from the peer's own session lock through
#    bin/fm-lock.sh - which stays the one owner of "is this harness pid alive".
#    A stale entry is therefore inert, and pruned the next time it is read.
#
# 3. THE PER-TASK TEMP ROOT'S NAME, which has to carry the home because /tmp does
#    not. Task ids are short kebab slugs, so two instances both running a task
#    called "fix-login" is ordinary, not a coincidence - and it made them share one
#    0700 directory holding a forwarded-credential file, with either teardown
#    deleting the other's.
#
# Knobs: FM_PEER_CACHE_DIR (1 and 2), FM_CLONE_LOCK_WAIT_SECS (the lock).
# docs/configuration.md owns them.

# fm_peer_cache_dir: the shared, per-user runtime root for both mechanisms.
# XDG cache rather than /tmp for one concrete reason: bin/fm-scratch-reap.sh
# sweeps /tmp/fm-* host-wide at 24h, and a reaper that can delete a lock file
# out from under a live holder is a mutual-exclusion hole with no upside.
fm_peer_cache_dir() {
  printf '%s' "${FM_PEER_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/firstmate}"
}

# fm_peer_slug <path>: a filesystem-safe, collision-resistant slug for one
# physical path. The basename is carried so an operator reading the directory can
# tell what a lock guards without resolving a hash.
fm_peer_slug() {  # <path>
  local path=$1
  printf '%s-%s' "$(basename "$path")" "$(fm_peer_cksum "$path")"
}

fm_peer_cksum() {  # <string>
  printf '%s' "$1" | cksum | awk '{print $1}'
}

# fm_peer_realpath <path>: resolved if it exists, unchanged if it does not. An
# empty argument stays empty rather than becoming the caller's cwd, which is what
# `cd ""` would silently give.
fm_peer_realpath() {  # <path>
  local path=$1
  [ -n "$path" ] || return 0
  ( cd "$path" 2>/dev/null && pwd -P ) || printf '%s' "$path"
}

# --- 1. the per-clone write lock --------------------------------------------

fm_clone_lock_wait_secs() {
  local secs="${FM_CLONE_LOCK_WAIT_SECS:-}"
  case "$secs" in
    ''|*[!0-9]*) printf '60' ;;
    *) printf '%s' "$secs" ;;
  esac
}

# fm_clone_lock_path <clone-dir>: where the lock for this clone lives. Resolves
# the clone physically, so two homes reaching one shared clone by different
# spellings still contend.
fm_clone_lock_path() {  # <clone-dir>
  local clone=$1 real
  real=$(fm_peer_realpath "$clone")
  printf '%s/clone-locks/%s.lock' "$(fm_peer_cache_dir)" "$(fm_peer_slug "$real")"
}

# fm_clone_lock_run <clone-dir> <command> [args...]: run the command holding this
# clone's write lock, waiting up to fm_clone_lock_wait_secs for it.
# fm_clone_lock_try is the same thing without the wait, for a caller sweeping many
# clones that must not let one contended clone starve the rest.
#
# Both return what the command returned, or 75 (EX_TEMPFAIL) when the lock was not
# obtained, which the caller reports. Where flock is absent (stock macOS) the
# command simply runs unlocked, which is the behaviour every caller had before
# this library.
fm_clone_lock_run() {  # <clone-dir> <command> [args...]
  local clone=$1
  shift
  fm_clone_lock_hold "$(fm_clone_lock_wait_secs)" "$clone" "$@"
}

fm_clone_lock_try() {  # <clone-dir> <command> [args...]
  local clone=$1
  shift
  fm_clone_lock_hold 0 "$clone" "$@"
}

# The lock is held for the whole command and dropped when the subshell exits, so
# no caller can leak it down an early-return path - the reason this is a runner
# and not an acquire/release pair. `9>&-` closes the lock fd for the command, so
# anything it leaves running in the background cannot hold the clone after it.
fm_clone_lock_hold() {  # <wait-secs> <clone-dir> <command> [args...]
  local secs=$1 clone=$2 lock
  shift 2
  command -v flock >/dev/null 2>&1 || { "$@"; return $?; }
  lock=$(fm_clone_lock_path "$clone")
  mkdir -p "$(dirname "$lock")" 2>/dev/null || { "$@"; return $?; }
  (
    flock -w "$secs" 9 || exit 75
    "$@" 9>&-
  ) 9>"$lock"
}

# --- 2. the live-peer session registry --------------------------------------

fm_peer_registry_dir() {
  printf '%s/sessions' "$(fm_peer_cache_dir)"
}

# fm_peer_register <home> <state-dir> <fm-root>: record this session as live.
# Called by bin/fm-lock.sh once it owns the home lock. Identified by the STATE dir
# rather than the home, because state is what FM_STATE_OVERRIDE can move and what
# the liveness re-check has to be pointed at; the filename carries the home's
# basename so an operator reading the directory can tell whose entry it is.
fm_peer_register() {  # <home> <state-dir> <fm-root>
  local home=$1 state=$2 root=$3 dir
  [ -n "$home" ] && [ -n "$state" ] && [ -n "$root" ] || return 0
  dir=$(fm_peer_registry_dir)
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\n%s\n%s\n' "$home" "$state" "$root" \
    > "$dir/$(basename "$home")-$(fm_peer_cksum "$state")" 2>/dev/null || true
}

# fm_peer_live_homes <fm-root> <my-state-dir>: print the home path of every OTHER
# instance that is running from THIS checkout and whose session lock is held by a
# live harness, one per line.
# Liveness is asked of bin/fm-lock.sh, never re-implemented here; a peer whose
# lock is free or stale has its registry entry pruned on the way past. A peer on a
# different checkout is left alone entirely: its entry is not this caller's to
# prune, and its instance is none of this caller's business.
fm_peer_live_homes() {  # <fm-root> <my-state-dir>
  local root=$1 mine=$2 dir entry home state peer_root real_root
  dir=$(fm_peer_registry_dir)
  [ -d "$dir" ] || return 0
  real_root=$(fm_peer_realpath "$root")
  for entry in "$dir"/*; do
    [ -f "$entry" ] || continue
    home=$(sed -n '1p' "$entry" 2>/dev/null)
    state=$(sed -n '2p' "$entry" 2>/dev/null)
    peer_root=$(sed -n '3p' "$entry" 2>/dev/null)
    [ -n "$home" ] && [ -n "$state" ] && [ -n "$peer_root" ] \
      || { rm -f "$entry" 2>/dev/null || true; continue; }
    [ "$state" != "$mine" ] || continue
    [ "$(fm_peer_realpath "$peer_root")" = "$real_root" ] || continue
    if [ ! -d "$state" ]; then
      rm -f "$entry" 2>/dev/null || true
      continue
    fi
    case "$(env FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$root/bin/fm-lock.sh" status 2>/dev/null)" in
      *"held by live harness"*) printf '%s\n' "$home" ;;
      *) rm -f "$entry" 2>/dev/null || true ;;
    esac
  done
}

# --- 3. the per-task temp root ----------------------------------------------

# fm_task_tmp_root <home> <task-id>: the per-task temp root under /tmp, scoped to
# the instance that owns the task. bin/fm-spawn.sh creates it and records it as
# meta `tasktmp=`; bin/fm-teardown.sh removes it.
#
# The home is resolved physically, so an instance that spells its own FM_HOME two
# ways across a spawn and a teardown still names one directory.
#
# It stays FLAT and keeps the `fm-` prefix on purpose: bin/fm-scratch-reap.sh
# reclaims orphans with a host-wide `/tmp/fm-*` glob at depth 1, and a per-home
# subdirectory would hide every orphan from it. That sweep stays host-wide and
# un-scoped for the same reason it exists - the orphans it reclaims are the ones
# whose owning home may be gone, so mtime, not ownership, is its safety property,
# and narrowing it to this home would reclaim strictly less.
fm_task_tmp_root() {  # <home> <task-id>
  local home=$1 id=$2 real
  real=$(fm_peer_realpath "$home")
  printf '/tmp/fm-%s-%s' "$(fm_peer_slug "$real")" "$id"
}
