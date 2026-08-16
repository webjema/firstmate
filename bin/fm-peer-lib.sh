#!/usr/bin/env bash
# fm-peer-lib.sh - what one firstmate instance knows about the OTHER instances
# sharing this host. Sourced by bin/fm-fleet-sync.sh, bin/fm-update.sh and
# bin/fm-lock.sh.
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
#    clone never corrupts; it goes STALE, because the loser's whole reason for
#    running was to advance it and it gave up instead. The lock therefore makes
#    the loser WAIT and then do its work. A lock that made it refuse faster would
#    solve nothing that was broken.
#    flock, so the kernel releases it when the holder dies - crash, SIGKILL,
#    reboot - which is the same reason bin/fm-pool-lib.sh prefers it for the pool.
#    Bounded (FM_CLONE_LOCK_WAIT_SECS), because a wedged holder must not hang a
#    sync that bin/fm-bootstrap.sh runs under its own timeout; on expiry the
#    caller reports and skips, which is exactly today's behaviour and no worse.
#    NOTHING IS WRITTEN INSIDE THE CLONE. AGENTS.md rail 1 is that firstmate never
#    writes to projects/, and a lock file under .git would break it for no gain,
#    so the locks live in the cache dir below, keyed by the clone's PHYSICAL path -
#    which is what makes two homes pointing at one shared clone contend.
#
# 2. THE LIVE-PEER SESSION REGISTRY, which answers "is another instance mid-turn
#    right now". bin/fm-update.sh needs it because a self-update fast-forwards
#    $FM_ROOT, and under sharing that is the checkout every peer is running from:
#    one instance's update swaps bin/ beneath the others mid-turn.
#    A peer is discoverable only if it says so, because nothing else ties the
#    instances together - each home knows its checkout, the checkout knows no
#    homes. So bin/fm-lock.sh registers each session as it acquires its home lock.
#    The registry is VOLATILE by design and lives in the cache dir, never in
#    $FM_HOME: an entry is a pid-backed claim, meaningless after a reboot, and
#    liveness is always re-derived from the peer's own session lock through
#    bin/fm-lock.sh - which stays the one owner of "is this harness pid alive".
#    A stale entry is therefore inert, and pruned the next time it is read.
#
# Knobs: FM_PEER_CACHE_DIR (both), FM_CLONE_LOCK_WAIT_SECS (the lock).
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
  printf '%s-%s' "$(basename "$path")" "$(printf '%s' "$path" | cksum | awk '{print $1}')"
}

# --- 1. the per-clone write lock --------------------------------------------

fm_clone_lock_wait_secs() {
  local secs="${FM_CLONE_LOCK_WAIT_SECS:-}"
  case "$secs" in
    ''|*[!0-9]*) printf '300' ;;
    *) printf '%s' "$secs" ;;
  esac
}

# fm_clone_lock_path <clone-dir>: where the lock for this clone lives. Resolves
# the clone physically, so two homes reaching one shared clone by different
# spellings still contend.
fm_clone_lock_path() {  # <clone-dir>
  local clone=$1 real
  real=$(cd "$clone" 2>/dev/null && pwd -P) || real=$clone
  printf '%s/clone-locks/%s.lock' "$(fm_peer_cache_dir)" "$(fm_peer_slug "$real")"
}

# fm_clone_lock_run <clone-dir> <command> [args...]: run the command holding this
# clone's write lock, and return what it returned. The lock is held for the whole
# command and dropped when the subshell exits, so no caller can leak it down an
# early-return path - the reason this is a runner and not an acquire/release pair.
# Returns 75 (EX_TEMPFAIL) if the wait expires, which the caller reports; where
# flock is absent (stock macOS) the command simply runs unlocked, which is the
# behaviour every caller had before this library.
fm_clone_lock_run() {  # <clone-dir> <command> [args...]
  local clone=$1 lock
  shift
  command -v flock >/dev/null 2>&1 || { "$@"; return $?; }
  lock=$(fm_clone_lock_path "$clone")
  mkdir -p "$(dirname "$lock")" 2>/dev/null || { "$@"; return $?; }
  (
    flock -w "$(fm_clone_lock_wait_secs)" 9 || exit 75
    "$@"
  ) 9>"$lock"
}

# --- 2. the live-peer session registry --------------------------------------

fm_peer_registry_dir() {
  printf '%s/sessions' "$(fm_peer_cache_dir)"
}

# fm_peer_register <home> <state-dir>: record this session as live. Called by
# bin/fm-lock.sh once it owns the home lock. Keyed by the STATE dir rather than
# the home, because state is what FM_STATE_OVERRIDE can move and what the
# liveness re-check has to be pointed at.
fm_peer_register() {  # <home> <state-dir>
  local home=$1 state=$2 dir
  [ -n "$home" ] && [ -n "$state" ] || return 0
  dir=$(fm_peer_registry_dir)
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\n%s\n' "$home" "$state" > "$dir/$(fm_peer_slug "$state")" 2>/dev/null || true
}

# fm_peer_live_homes <fm-root> <my-state-dir>: print the home path of every OTHER
# instance whose session lock is held by a live harness, one per line.
# Liveness is asked of bin/fm-lock.sh, never re-implemented here; a peer whose
# lock is free or stale has its registry entry pruned on the way past.
fm_peer_live_homes() {  # <fm-root> <my-state-dir>
  local root=$1 mine=$2 dir entry home state
  dir=$(fm_peer_registry_dir)
  [ -d "$dir" ] || return 0
  for entry in "$dir"/*; do
    [ -f "$entry" ] || continue
    home=$(sed -n '1p' "$entry" 2>/dev/null)
    state=$(sed -n '2p' "$entry" 2>/dev/null)
    [ -n "$home" ] && [ -n "$state" ] || { rm -f "$entry" 2>/dev/null || true; continue; }
    [ "$state" != "$mine" ] || continue
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
