#!/usr/bin/env bash
# fm-pool-lib.sh - the single owner of "what does firstmate know about a treehouse
# pool". Sourced by bin/fm-pool-warm.sh and bin/fm-pool-status.sh.
#
# treehouse (the external Go binary) owns the pool; firstmate only READS it, and
# fm_pool_read is the one place that does. It never parses the human `treehouse
# status` table: its columns, `~/` abbreviation, indented process lines and banners
# changed shape between v2 and v3. It reads a machine source instead:
#
#   treehouse v3.0.0+  `treehouse status --json` - a documented array of
#                      {name, status, path, lease_holder, ...}.
#   treehouse v2.x     no --json. The pool's own treehouse-state.json (unversioned
#                      in v2) plus git and the process table, deriving each slot's
#                      state exactly as v2's pool.List does (cmd/status.go and
#                      internal/pool/pool.go at v2.0.0, read 2026-09-30).
#
# Slot states: available, in-use, leased, dirty (v3 adds damaged, unverified and
# "you're here"). Only `available` is a slot `treehouse get` can hand over.
#
# DIRTY IS THE ONE THAT BITES (verified, 2026-07-14): `treehouse get` SKIPS a
# dirty slot forever, and `treehouse prune` REFUSES to reclaim it ("Skipped 1
# unsafe idle worktree: uncommitted changes"). A crew that dies mid-task - three
# box reboots did exactly this - leaves its slot dirty, and the pool silently
# shrinks with nothing noticing. bin/fm-pool-status.sh exists to notice.
set -u

# fm_repo_url_canonical: the one owner of "are these two remote URLs the same repo".
# Unset after use so this lib leaves nothing but fm_pool_* in a sourcing shell.
_FM_POOL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-repo-url-lib.sh
. "$_FM_POOL_LIB_DIR/fm-repo-url-lib.sh"
unset _FM_POOL_LIB_DIR

# fm_pool_key <project-real-path>: a stable, filesystem-safe slug for one POOL.
#
# TREEHOUSE DOES NOT KEY A POOL BY THE CLONE'S PATH, and an earlier version of this
# comment said it did. Measured 2026-08-16 against treehouse v2.0.0, two ways: by
# reading five live pool directory names on this box against their clones'
# `git remote get-url origin`, and by making scratch clones with a redirected pool
# root. Shape of the result, with the operator's own names generalised:
#
#   ~/.treehouse/<basename>-<6 hex>   <-- first 6 hex of sha256(origin URL)
#
#   repo-e3a59a    https://host/org/repo        three spellings of ONE upstream,
#   repo-d1d768    https://host/org/repo.git      three separate pools
#   repo-f860c9    git@host:org/repo.git
#   other-a9b5a3   (no origin remote)           <-- sha256 of the repo PATH
#
# TREEHOUSE COMPARES THE URL LITERALLY, so `.git`, a trailing slash and the ssh
# spelling are three different pools, and this box really does carry three for one
# upstream. Two clones at DIFFERENT paths with the same basename and the
# same URL are ONE pool - which is exactly the case the old key got wrong: two homes
# each holding projects/<name> addressed one pool while taking two different locks
# keyed by their own paths, so they did not exclude each other at all and could both
# warm it, over-provisioning by GBs. Hashing the URL instead of the path was that fix;
# the dep-cache lock beside this one was always keyed by the real pool directory
# (bin/fm-worktree-provision.sh pool_key_of).
#
# THIS KEY IS DELIBERATELY NOT TREEHOUSE'S DIRECTORY NAME, and hashing the LITERAL url
# is what it stopped doing (2026-08-28). Mirroring treehouse exactly gave firstmate one
# independent warm lock and one independent disk budget PER SPELLING, so it would warm
# `repo.git`'s pool and `repo`'s pool concurrently, each to its own ceiling, while
# believing it was managing two unrelated pools. It was filling the fragmentation it
# should have been refusing to feed. The key now hashes the CANONICAL repository
# identity, which bin/fm-repo-url-lib.sh owns along with what it does and does not
# fold. Steady-state that is a COARSER lock than a treehouse pool, never a finer one:
# it can only serialise two warms that should never have raced. What the lock needs is
# that two homes on one pool derive the SAME string, not that the string equals
# treehouse's directory name; the basename stays so the key still reads next to the
# pool family it guards.
#
# CHANGING THIS VALUE RENAMES A LIVE LOCK, and "steady-state" above is the whole
# caveat. The lock is a file named by this key (bin/fm-pool-warm.sh), so a warmer
# holding the old name is invisible to one taking the new name, and two warmers then
# fill one pool - the exact over-provisioning the lock exists to prevent. Secondmate
# homes carry their OWN bin/ and are fast-forwarded by /updatefirstmate, so the window
# shuts when the LAST home updates, not the first: change this with no warm in flight
# and update every home in one pass. The orphaned files are harmless in themselves -
# zero bytes, and flock on an unheld file succeeds - but nothing collects them, so
# ~/.treehouse/.fm-warm-locks still carries the path-keyed generation this file
# replaced in 2026-08-16 (`aisha-832807002.lock`) beside the URL-keyed one it replaced
# today (`aisha-30bace.lock`). That residue is what this hazard looks like afterwards.
#
# A clone with no origin remote falls back to the physical path, which is what
# this function always did: without a remote there is no shared identity to key
# by, and per-path is then the honest answer.
fm_pool_key() {  # <project-real-path>
  local path=$1 url hash
  url=$(fm_repo_url_canonical "$(git -C "$path" remote get-url origin 2>/dev/null || true)")
  if [ -n "$url" ]; then
    hash=$(printf '%s' "$url" | fm_pool_sha256 | cut -c1-6)
  fi
  [ -n "${hash:-}" ] || hash=$(printf '%s' "$path" | cksum | awk '{print $1}')
  printf '%s-%s' "$(basename "$path")" "$hash"
}

# fm_pool_sha256: hex sha256 of stdin. Mirrors bin/fm-session-start.sh's ladder
# because stock macOS ships `shasum` and not `sha256sum`; prints nothing when
# neither exists, which sends fm_pool_key to its path fallback.
fm_pool_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  fi
}

fm_pool_has_slots() {  # <project-real-path>
  # Does this project have any treehouse slots at all? Answered from GIT, not from
  # treehouse - because `treehouse status` is NOT read-only: merely asking it about
  # a repo CREATES that repo's pool directory (verified 2026-07-14, and v3's
  # `status --json` runs the same code). A diagnostic that sweeps every project
  # must not leave a trail of empty pools behind it, and a test suite must not
  # litter the operator's real ~/.treehouse.
  # A pool slot is a linked git worktree of the project, so git already knows. A
  # project with no linked worktree has no slots, hence nothing to diagnose - and
  # that includes no dirty slot, so this guard cannot hide the incident.
  [ "$(git -C "$project" worktree list --porcelain 2>/dev/null | grep -c '^worktree ')" -gt 1 ]
}

# fm_pool_read <project-real-path>: read the pool once. Returns 1 when the pool
# cannot be read at all (not a pool, treehouse errored) or when its machine output
# or state file is in a shape this reader does not know - it says which on stderr
# and never guesses. On success sets:
#   FM_POOL_TABLE      one line per slot: "<name>\t<state>\t<path>\t<lease-holder>"
#   FM_POOL_SLOTS      total slot count
#   FM_POOL_AVAILABLE  slots that are free AND warm - i.e. what a `treehouse get`
#                      could actually hand over right now
#   FM_POOL_DIR        the pool directory (parent of the slots), or empty
fm_pool_read() {  # <project-real-path>
  local project=$1 rows name state path holder
  FM_POOL_TABLE=""
  FM_POOL_SLOTS=0
  FM_POOL_AVAILABLE=0
  FM_POOL_DIR=""
  [ -d "$project" ] || return 1
  if treehouse status --help 2>/dev/null | grep -q -- '--json'; then
    rows=$(fm_pool_rows_json "$project") || return 1
  else
    rows=$(fm_pool_rows_state "$project") || return 1
  fi
  while IFS=$(printf '\t') read -r name state path holder; do
    [ -n "$name" ] || continue
    FM_POOL_SLOTS=$((FM_POOL_SLOTS + 1))
    [ "$state" = available ] && FM_POOL_AVAILABLE=$((FM_POOL_AVAILABLE + 1))
    [ -n "$FM_POOL_DIR" ] || FM_POOL_DIR=$(dirname "$(dirname "$path")")
    FM_POOL_TABLE="${FM_POOL_TABLE}${name}	${state}	${path}	${holder}
"
  done <<ROWS
$rows
ROWS
  return 0
}

fm_pool_unrecognised() {  # <project> <what>
  printf 'fm_pool_read: %s: unrecognised %s - refusing to guess the pool state\n' \
    "$(basename "$1")" "$2" >&2
}

# One "<name>\t<state>\t<path>\t<holder>" row per slot, from treehouse v3+.
fm_pool_rows_json() {  # <project-real-path>
  local project=$1 out
  out=$( (cd "$project" && treehouse status --json 2>/dev/null) ) || return 1
  [ -n "$out" ] && printf '%s' "$out" | jq -r '
    if type != "array" then error("not an array") else .[] end
    | if (.name | type) == "string" and (.status | type) == "string"
         and (.path | type) == "string"
      then [.name, .status, .path, (.lease_holder // "")] | @tsv
      else error("slot without name, status or path") end' 2>/dev/null \
    || { fm_pool_unrecognised "$project" "treehouse status --json output"; return 1; }
}

# The same rows for treehouse v2, which has no --json: its state file says which
# slots exist and which are leased or owned; git and the process table say the rest.
# The order below is v2's pool.List, and it matters: a leased slot is leased even
# with processes in it, and a slot with processes is in-use even when dirty.
fm_pool_rows_state() {  # <project-real-path>
  local project=$1 pool entries cwds='' cwds_read=no name path leased pid started holder
  local state real c
  pool=$(fm_pool_state_dir "$project") || return 1
  [ -n "$pool" ] || return 0
  # v2 writes no "version"; v3 writes one and reinterprets entries on read
  # (quarantine, recovery), so a versioned file is not ours to interpret.
  entries=$(jq -r '
    if type != "object" or (.version // 0) != 0
       or ((.worktrees // []) | type) != "array"
      then error("unknown state layout") else (.worktrees // [])[] end
    | if (.name | type) == "string" and (.path | type) == "string"
      then . else error("slot without name or path") end
    | select(.destroying != true)
    | [.name, .path, (.leased == true | tostring), (.owner_pid // 0 | tostring),
       (.owner_started_at // 0 | tostring), (.lease_holder // "")] | @tsv' \
    "$pool/treehouse-state.json" 2>/dev/null) \
    || { fm_pool_unrecognised "$project" "$pool/treehouse-state.json"; return 1; }
  while IFS=$(printf '\t') read -r name path leased pid started holder; do
    [ -n "$name" ] || continue
    # v2 heals a slot whose directory is gone out of the pool on every read.
    [ -d "$path" ] || continue
    if [ "$leased" = true ]; then
      printf '%s\tleased\t%s\t%s\n' "$name" "$path" "$holder"
      continue
    fi
    state=available
    if fm_pool_pid_started "$pid" "$started"; then
      state=in-use
    else
      if [ "$cwds_read" = no ]; then
        cwds=$(fm_pool_cwds) || {
          printf 'fm_pool_read: %s: cannot list process working directories to tell in-use slots apart\n' \
            "$(basename "$project")" >&2
          return 1
        }
        cwds_read=yes
      fi
      real=$(cd "$path" && pwd -P)
      while IFS= read -r c; do
        case "$c" in "$real"|"$real"/*) state=in-use; break ;; esac
      done <<CWDS
$cwds
CWDS
      if [ "$state" = available ] \
         && [ -n "$(git -C "$path" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
        state=dirty
      fi
    fi
    printf '%s\t%s\t%s\t\n' "$name" "$state" "$path"
  done <<ENTRIES
$entries
ENTRIES
}

# The pool directory holding this project's slots: a slot is a linked worktree at
# <pool>/<slot>/<repo>, and a pool holds treehouse-state.json. Prints nothing when
# no slot lives in a pool. A clone whose origin was re-spelled can have slots in
# two pools; treehouse reads only the one named by the CURRENT origin
# (<repo>-<first 6 hex of sha256(origin url, else the repo path)>), so that wins.
fm_pool_state_dir() {  # <project-real-path>
  local project=$1 dirs top url d
  dirs=$(git -C "$project" worktree list --porcelain 2>/dev/null \
    | sed -n 's/^worktree //p' | tail -n +2 \
    | while IFS= read -r wt; do
        d=$(dirname "$(dirname "$wt")")
        [ -f "$d/treehouse-state.json" ] && printf '%s\n' "$d"
      done | sort -u)
  case "$dirs" in
    *"
"*) ;;
    *) printf '%s' "$dirs"; return 0 ;;
  esac
  top=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || top=$project
  url=$(git -C "$project" remote get-url origin 2>/dev/null) || url=$top
  d="$(basename "$top")-$(printf '%s' "$url" | fm_pool_sha256 | cut -c1-6)"
  printf '%s\n' "$dirs" | while IFS= read -r c; do
    [ "$(basename "$c")" = "$d" ] && printf '%s' "$c"
  done | grep . \
    || { fm_pool_unrecognised "$project" "slot layout: slots in several pools, none named for the current origin"; return 1; }
}

# fm_pool_pid_started <pid> <started-ms>: is the recorded owner still that process?
# treehouse records the start time (gopsutil CreateTime, epoch ms) beside the pid
# so a recycled pid is not mistaken for the owner. It is recomputed from /proc and
# compared within a second; without /proc only liveness can be checked.
fm_pool_pid_started() {  # <pid> <started-ms>
  local pid=$1 want=$2 have
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  case "$want" in ''|0|*[!0-9]*) return 1 ;; esac
  if [ ! -d /proc/self ]; then
    ps -p "$pid" >/dev/null 2>&1
    return
  fi
  have=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk \
    -v btime="$(awk '/^btime/ {print $2}' /proc/stat)" \
    -v hz="$(getconf CLK_TCK 2>/dev/null || echo 100)" \
    '{ printf "%d", ($20 / hz + btime) * 1000 }')
  [ -n "$have" ] || return 1
  [ $((have - want)) -le 1000 ] && [ $((want - have)) -le 1000 ]
}

# Every process's working directory, one per line (symlinks already resolved).
fm_pool_cwds() {
  if [ -d /proc/self ]; then
    find /proc/[0-9]*/cwd -maxdepth 0 -printf '%l\n' 2>/dev/null || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
  else
    return 1
  fi
}

# fm_pool_max_trees <project-real-path>: treehouse's own pool ceiling. Its
# treehouse.toml owns the value; 16 is treehouse's documented default.
fm_pool_max_trees() {  # <project-real-path>
  local project=$1 value
  value=$(sed -n 's/^[[:space:]]*max_trees[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "$project/treehouse.toml" 2>/dev/null | head -n 1)
  case "${value:-}" in
    ''|*[!0-9]*) printf '16' ;;
    *) printf '%s' "$value" ;;
  esac
}

# fm_pool_disk_budget_gb <config-dir>: the per-project-pool disk ceiling, in GB.
# Precedence: FM_POOL_DISK_BUDGET_GB, then config/pool-disk-budget-gb, then 20.
# docs/configuration.md owns the knob.
fm_pool_disk_budget_gb() {  # <config-dir>
  local config=$1 value="${FM_POOL_DISK_BUDGET_GB:-}"
  if [ -z "$value" ] && [ -f "$config/pool-disk-budget-gb" ]; then
    value=$(tr -d '[:space:]' < "$config/pool-disk-budget-gb" 2>/dev/null || true)
  fi
  case "${value:-}" in
    ''|*[!0-9]*) printf '20' ;;
    *) printf '%s' "$value" ;;
  esac
}

# fm_pool_disk_budget_kb <config-dir>: the same ceiling in KB, which is the unit
# the check actually works in. FM_POOL_DISK_BUDGET_KB is an INTERNAL override so
# the behavior test can exercise the budget with a few small files instead of
# staging 20 GB; operators set the GB knob above.
fm_pool_disk_budget_kb() {  # <config-dir>
  local kb="${FM_POOL_DISK_BUDGET_KB:-}"
  case "$kb" in
    ''|*[!0-9]*) printf '%s' "$(( $(fm_pool_disk_budget_gb "$1") * 1024 * 1024 ))" ;;
    *) printf '%s' "$kb" ;;
  esac
}

# fm_pool_gb <kb>: kilobytes as GB with one decimal, for operator-facing numbers.
fm_pool_gb() {  # <kb>
  awk -v kb="${1:-0}" 'BEGIN { printf "%.1f", kb / 1048576 }'
}

# fm_pool_run_bounded <secs> <command> [args...]: the single owner of "how a warm
# step is time-bounded". Runs the command with a hard ceiling and returns 124 on
# expiry, exactly as `timeout` does.
#
# It exists because stock macOS ships NO `timeout`, and the callers used to degrade
# to an unbounded run there - which is precisely the failure the bound exists to
# prevent (a hung step holds the treehouse lease and the pool lock with a LIVE pid,
# so nothing may reclaim either, and the leak report is suppressed too). That was
# survivable while the only bounded step was a `treehouse get`; it is not now that
# a dependency install runs on the warm path and can hang for as long as a dead
# registry stays dead.
#
# Only the direct child is signalled, which is `timeout`'s own behavior: the point
# is to free the lease and the lock, not to guarantee no orphan survives.
fm_pool_run_bounded() {  # <secs> <command> [args...]
  local secs=$1 pid waited=0 rc
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    return $?
  fi
  "$@" &
  pid=$!
  while [ "$waited" -lt "$secs" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 124
  fi
  wait "$pid"
  rc=$?
  return $rc
}

# fm_pool_lease <project-real-path> <holder> [timeout-secs]: reserve a slot,
# creating-or-resetting it, and print its path. treehouse installs NOTHING here -
# the slot comes back empty, and populating it is bin/fm-worktree-provision.sh's
# job, which fm-pool-warm.sh calls while this lease is still held.
# BOUNDED when a timeout is given (exit 124 on expiry): a reset that hangs must not
# hold a lease and a pool lock forever. See bin/fm-pool-warm.sh.
fm_pool_lease() {  # <project-real-path> <holder> [timeout-secs]
  local project=$1 holder=$2 secs=${3:-}
  if [ -n "$secs" ] && [ "$secs" -gt 0 ] 2>/dev/null; then
    (cd "$project" 2>/dev/null \
      && fm_pool_run_bounded "$secs" treehouse get --lease --lease-holder "$holder" 2>/dev/null)
  else
    (cd "$project" 2>/dev/null && treehouse get --lease --lease-holder "$holder" 2>/dev/null)
  fi
}

# fm_pool_warm_timeout: the ceiling on ONE warm, in seconds. Default 1800 - over
# 13x the measured 137s cold optiroq install, so a legitimately slow project is
# never cut short, while a genuinely hung one cannot hold the pool forever.
fm_pool_warm_timeout() {
  local secs="${FM_POOL_WARM_TIMEOUT:-}"
  case "$secs" in
    ''|*[!0-9]*) printf '1800' ;;
    *) printf '%s' "$secs" ;;
  esac
}

# fm_pool_boot_id: an identifier that CHANGES on every reboot. A pid alone is not
# an identity for anything that outlives a boot: the warm lock lives under
# ~/.treehouse and survives reboot, so a recorded pid can be re-used by an
# unrelated live process afterwards - making a long-dead warmer look alive forever.
# Linux exposes a real boot id; elsewhere, fall back to the boot time from uptime,
# and finally to a constant (which degrades to pid-only, never worse than before).
fm_pool_boot_id() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    tr -d '[:space:]' < /proc/sys/kernel/random/boot_id
  elif [ -r /proc/stat ] && grep -q '^btime' /proc/stat 2>/dev/null; then
    sed -n 's/^btime[[:space:]]*//p' /proc/stat | head -n 1 | tr -d '[:space:]'
  else
    printf 'no-boot-id'
  fi
}

# --- the pool lock ----------------------------------------------------------
#
# ONE warmer per pool (secondmate homes share pools; two warmers racing
# over-provision by GBs). Two implementations, because the guarantee is worth the
# code:
#
# flock (default, and what this box and CI have). The kernel owns the lock and
#   RELEASES IT WHEN THE HOLDER DIES - crash, SIGKILL, reboot, all of it. That
#   removes the whole class of bug the alternative keeps re-inventing: there is no
#   stale lock to reclaim, so there is no reclaim race, and no need to ask whether
#   a recorded pid is still the process that recorded it.
#
# directory + pid + boot id (fallback where flock is absent, e.g. stock macOS).
#   Here a stale lock is real and MUST be reclaimed, or one crash disables a pool's
#   warming forever. But the naive reclaim (`rm -rf` then `mkdir`) is a TOCTOU that
#   creates exactly the two warmers the lock prevents: both contenders judge the
#   owner dead; A recreates the lock and starts warming; B - still acting on its own
#   stale judgement - removes A's LIVE lock and takes its own. Renaming instead of
#   removing does not fix it either: the rename targets the PATH, and by then that
#   path holds A's new lock. So the right to reclaim is itself taken atomically
#   (mkdir of a reclaim dir), and only its winner may touch the lock.
#   Liveness there is pid AND boot id: the lock outlives a reboot, so a bare pid can
#   be recycled by an unrelated process - which would make a long-dead warmer look
#   alive forever, wedging the pool AND suppressing its leaked-lease report.
#
# FM_POOL_LOCK_FORCE_DIR=1 selects the fallback explicitly (the tests exercise both).

fm_pool_lock_use_flock() {
  [ "${FM_POOL_LOCK_FORCE_DIR:-0}" = 1 ] && return 1
  command -v flock >/dev/null 2>&1
}

# fm_pool_lock_acquire <lock-base>: returns 0 iff THIS process now holds the pool
# lock. Must run in the caller's own shell (it keeps an open fd).
fm_pool_lock_acquire() {  # <lock-base>
  local base=$1 reclaim
  mkdir -p "$(dirname "$base")" 2>/dev/null || return 1

  if fm_pool_lock_use_flock; then
    exec {FM_POOL_LOCK_FD}>"$base.lock" 2>/dev/null || return 1
    if flock -n "$FM_POOL_LOCK_FD" 2>/dev/null; then
      return 0
    fi
    exec {FM_POOL_LOCK_FD}>&- 2>/dev/null || true
    FM_POOL_LOCK_FD=
    return 1
  fi

  fm_pool_lock_claim_dir "$base" && return 0
  fm_pool_owner_alive "$base" && return 1     # a live warmer owns this pool

  # Stale. Take the RIGHT to reclaim atomically; only its winner may touch the lock.
  reclaim="$base.reclaim"
  mkdir "$reclaim" 2>/dev/null || return 1
  if fm_pool_owner_alive "$base"; then        # re-check under the reclaim lock
    rmdir "$reclaim" 2>/dev/null || true
    return 1
  fi
  rm -rf "$base" 2>/dev/null || true
  local rc
  fm_pool_lock_claim_dir "$base"
  rc=$?
  rmdir "$reclaim" 2>/dev/null || true
  return $rc
}

fm_pool_lock_claim_dir() {  # <lock-base>
  local base=$1
  mkdir "$base" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$base/pid" 2>/dev/null || true
  fm_pool_boot_id > "$base/boot" 2>/dev/null || true
  FM_POOL_LOCK_HELD=$base
  return 0
}

fm_pool_lock_release() {
  if [ -n "${FM_POOL_LOCK_FD:-}" ]; then
    exec {FM_POOL_LOCK_FD}>&- 2>/dev/null || true   # the kernel drops the flock
    FM_POOL_LOCK_FD=
  fi
  if [ -n "${FM_POOL_LOCK_HELD:-}" ]; then
    rm -rf "$FM_POOL_LOCK_HELD" 2>/dev/null || true
    FM_POOL_LOCK_HELD=
  fi
}

# fm_pool_warmer_live <lock-base>: is a warmer working this pool RIGHT NOW?
# Used by fm-pool-status.sh to decide whether a held warm lease is a warmer doing
# its job or a lease leaked by a dead one. Under flock this is exact: if we can
# take the lock, nobody holds it.
fm_pool_warmer_live() {  # <lock-base>
  local base=$1 fd
  if fm_pool_lock_use_flock; then
    [ -e "$base.lock" ] || return 1
    exec {fd}>"$base.lock" 2>/dev/null || return 1
    if flock -n "$fd" 2>/dev/null; then
      flock -u "$fd" 2>/dev/null || true
      exec {fd}>&- 2>/dev/null || true
      return 1                                 # we took it: no live warmer
    fi
    exec {fd}>&- 2>/dev/null || true
    return 0                                   # someone holds it
  fi
  fm_pool_owner_alive "$base"
}

# fm_pool_owner_alive <lock-dir>: is the warmer that took this lock still running?
# TRUE only when the recorded pid is alive AND was recorded on THIS boot. Anything
# else - no pid, dead pid, a pid from a previous boot (so possibly recycled), or an
# unreadable lock - is not a live owner, and the lock is reclaimable.
# Getting this wrong in the "alive" direction is the expensive one: it wedges a
# pool's warming permanently and hides its leaked lease from the report.
fm_pool_owner_alive() {  # <lock-dir>
  local lock=$1 pid boot
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  case "${pid:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  boot=$(cat "$lock/boot" 2>/dev/null || true)
  # No boot marker: written by an older version, or unreadable. Treat as a previous
  # boot - reclaimable - rather than trusting a bare pid across an unknown span.
  [ -n "$boot" ] || return 1
  [ "$boot" = "$(fm_pool_boot_id)" ]
}

# fm_pool_leased_by <project-real-path> <holder>: the slot path treehouse says is
# leased by <holder>, or empty.
# This is what makes a mid-warm kill recoverable. `treehouse get --lease` marks
# the lease BEFORE it does its work and only prints the path at the END, so a
# warmer killed before that (a reboot) holds a real lease whose path it never
# learned - and could not release it by path even though it must. treehouse's own
# status reports the holder, so ask it.
fm_pool_leased_by() {  # <project-real-path> <holder>
  local project=$1 holder=$2 slot state path lease
  fm_pool_read "$project" || return 0
  while IFS=$(printf '\t') read -r slot state path lease; do
    [ -n "${slot:-}" ] || continue
    [ "$state" = leased ] || continue
    [ "$lease" = "$holder" ] || continue
    printf '%s' "$path"
    return 0
  done <<EOF
$FM_POOL_TABLE
EOF
  return 0
}

# fm_pool_lease_held <project-real-path> <slot-path>: does treehouse still report
# <slot-path> as leased?
#
# STRICTLY ONE SLOT, DELIBERATELY. An earlier draft also answered "held" when any
# OTHER slot in the pool carried the same holder, and that is wrong twice over: the
# leak this branch fixes leaves SEVERAL slots under one fm-warm-<name> holder, so a
# perfectly good release would be reported FAILED - and the caller's retry would then
# force a path it had already returned, which by then may belong to a crew.
#
# FAILS CLOSED. A pool it cannot read is a pool whose lease it cannot see gone, and
# reporting an unverified release is the exact failure fm_pool_release exists to end.
# A path with no row at all is NOT held: the slot is not in the pool, so nothing can
# be leasing it, and forcing it again could only reach a stranger.
fm_pool_lease_held() {  # <project-real-path> <slot-path>
  local project=$1 slot=$2 name state path lease
  [ -n "$slot" ] || return 1
  fm_pool_read "$project" || return 0
  while IFS=$(printf '\t') read -r name state path lease; do
    [ -n "${name:-}" ] || continue
    [ "$state" = leased ] || continue
    [ "$path" = "$slot" ] && return 0
  done <<EOF
$FM_POOL_TABLE
EOF
  return 1
}

# fm_pool_release <project-real-path> <slot-path>: release the lease, and
# CONFIRM it was released. The slot's installed dependencies SURVIVE this
# (treehouse's reset is `git clean -fd`, no -x, so gitignored trees are kept) -
# which is what leaves it available AND warm.
#
# --force IS NOT COSMETIC, AND THE EXIT CODE IS NOT THE VERDICT. `treehouse return`
# on a worktree with an uncommitted TRACKED file prompts "Worktree has uncommitted
# changes. Clean and return? [Y/n]", and a warmer runs detached with no terminal to
# answer it - so treehouse prints "Aborted.", leaves the lease held, and EXITS 0
# (reproduced by hand, treehouse v2.0.0, 2026-08-12). The warm path believed that
# zero and logged the slot free. It was not: availability never rose, always-plus-one
# provisioned another slot every cycle, and the pool reached 6 slots / 17 GB on
# 2026-08-11 and 13 slots / 35.8 GB before that. bin/fm-teardown.sh and
# bin/fm-home-seed.sh have always forced; this was the one caller that did not.
#
# The slot is dirty in the first place because an operator's treehouse post_create
# hook installs dependencies INSIDE `treehouse get`, so the lockfile is already
# rewritten when bin/fm-worktree-provision.sh takes its "already modified" snapshot
# and correctly declines to restore it.
#
# FORCING DISCARDS NOTHING A HUMAN WROTE. Every caller is on the warm path
# (bin/fm-pool-warm.sh), releasing a lease taken under an fm-warm-<name> holder -
# this warm's own, or one a dead warm left behind - and a leased slot is never handed
# to a crew, so the only thing a force can clean off it is the installer's own
# lockfile rewrite.
# Crew and secondmate leases are held under a task id, never under fm-warm-*, and
# nothing here ever releases one.
#
# treehouse's stderr is kept for a FAILED release only, squashed to one line for the
# caller's log: a verified release is the routine case and stays silent, while a
# release that fails for some NEW reason must not. An unreadable pool says so in its
# own words, because that failure prints nothing on its own and "still LEASED" with
# no reason is how this bug hid for a month in the first place.
fm_pool_release() {  # <project-real-path> <slot-path>
  local project=$1 slot=$2 err
  err=$( (cd "$project" 2>/dev/null && treehouse return --force "$slot" >/dev/null) 2>&1 ) || true
  if fm_pool_lease_held "$project" "$slot"; then
    if ! fm_pool_read "$project"; then
      printf 'treehouse status is unreadable, so the release could not be verified\n' >&2
    elif [ -n "$err" ]; then
      printf 'treehouse return: %s\n' "$(printf '%s' "$err" | tr '\n' ' ')" >&2
    fi
    return 1
  fi
  return 0
}
