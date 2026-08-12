#!/usr/bin/env bash
# Tests for bin/fm-pool-warm.sh - the always-plus-one warm spare.
#
# The contract (its header owns the policy): for every project with work IN
# FLIGHT, at least one treehouse slot must sit free and WARM - dependencies
# already installed - so a crew never pays the cold install on the spawn path.
# When the last free slot is taken, the next is provisioned preventively, in the
# background, on firstmate's time.
#
# treehouse is stubbed (the suite's usual fakebin/PATH shim): a real warm would
# install multiple GB. The stub records every treehouse invocation, so these
# tests assert the exact commands - that warming IS `get --lease`, then the
# dependency provision, then `return`, and nothing reimplemented. treehouse
# itself installs nothing; bin/fm-worktree-provision.sh is what makes a warm slot
# warm, and tests/fm-worktree-provision.test.sh owns its cases.
#
#   (a) a free warm slot already exists          -> warms NOTHING (the common case)
#   (b) no free slot                             -> leases, installs, returns
#   (c) the lease is held across the whole install and released after
#   (d) the disk budget blocks a warm            -> reports the real numbers, no get
#   (e) treehouse's max_trees blocks a warm      -> reports it, no get
#   (f) a live warmer holds the POOL lock        -> the second warmer does nothing
#   (g) the pool lock is POOL-scoped, not home-scoped (secondmates share pools)
#   (h) a failed `treehouse get`                 -> logs, exits 0, breaks nothing
#   (i) an idle fleet (no work in flight)        -> warms nothing
#   (j) a stale pool lock (dead owner)           -> is reclaimed, not wedged forever
#   (k) a warmer KILLED mid-install              -> releases its lease (no lost slot)
#   (l) a HUNG install                           -> is bounded; lease and lock freed
#   (m) five warmers vs one stale lock           -> exactly one warm (no TOCTOU)
#   (n) a live pid from a PREVIOUS boot          -> not a live warmer; lock reclaimed
#   (o) no `timeout` binary on the box           -> the bound still holds (macOS)
#   (p) the leased slot is PROVISIONED before handover, under the warm's deadline
#   (q) a slot whose install FAILED is logged COLD, never as warmed
#   (r) ONE deadline for the whole warm, taken BEFORE the lease is asked for
#   (s) an installer that rewrites a TRACKED file leaves the slot CLEAN, not dirty
#   (t) a DIRTY slot is really released                -> the lease is gone, not "gone"
#   (u) a return that frees nothing                    -> reported FAILED, never WARMED
#   (v) a leaked warm lease of this pool's own holder  -> reclaimed, pool never grows
#   (w) a LIVE warmer's lease                          -> never reaped
#   (x) a crew's lease, and another project's warm     -> never reaped
#   (y) TWO leaked leases under one holder             -> releasing one is a SUCCESS
#   (z) a reclaim that CANNOT free its slot            -> grows the pool, never starves
#   (aa) a reclaim whose slot does not come back free  -> the ceilings still apply
#   (ab) a pool treehouse can no longer describe       -> unverifiable is a FAILURE
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WARM="$ROOT/bin/fm-pool-warm.sh"
TMP_ROOT=$(fm_test_tmproot fm-pool-warm)
mkdir -p "$TMP_ROOT"

# --- a sandbox: a firstmate home, a project clone, a scripted treehouse --------
#
# STATUS_FILE holds the scripted `treehouse status` output; TH_LOG records every
# treehouse call the script makes. GET_RC forces a failed acquire.
new_case() {  # <name> -> echoes the case dir
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/home/state" "$case_dir/home/config" "$case_dir/proj" \
           "$case_dir/fakebin" "$case_dir/th-root"
  : > "$case_dir/th.log"
  printf '0\n' > "$case_dir/get-rc"

  printf '0\n' > "$case_dir/get-delay"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'treehouse'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${TH_LOG:?}"
holder_of() { while [ $# -gt 0 ]; do [ "$1" = --lease-holder ] && { printf '%s' "$2"; return; }; shift; done; }
case "${1:-}" in
  status)
    # A pool treehouse can no longer describe. The release verdict is a STATUS read,
    # so this is the state in which a release cannot be verified either way.
    [ -n "${TH_STATUS_BREAK:-}" ] && [ -f "$TH_STATUS_BREAK" ] && exit 1
    cat "${TH_STATUS:?}"
    # Reality: treehouse's OWN status reports every held lease, its PATH and who
    # holds it. The stub must too, and must be able to report MORE THAN ONE under the
    # same holder - that is the state the leak actually produced (six of them), and a
    # stub that cannot express it cannot catch a release verdict that confuses "this
    # slot" with "any slot of this holder".
    if [ -f "${TH_LEASE_STATE:?}" ]; then
      while read -r lpath lholder; do
        [ -n "${lpath:-}" ] || continue
        printf '%s     leased       %s  (held by %s)\n' \
          "$(basename "$(dirname "$lpath")")" "$lpath" "$lholder"
      done < "$TH_LEASE_STATE"
    fi
    # ... and every slot a return has FREED, which a real pool reports as available
    # and hands back to the next `get`. Without it the stub can only ever grow.
    if [ -n "${TH_FREE_STATE:-}" ] && [ -f "$TH_FREE_STATE" ]; then
      while read -r fpath; do
        [ -n "${fpath:-}" ] || continue
        printf '%s     available    %s\n' "$(basename "$(dirname "$fpath")")" "$fpath"
      done < "$TH_FREE_STATE"
    fi
    ;;
  get)
    rc=$(cat "${TH_GET_RC:?}")
    [ "$rc" = 0 ] || exit "$rc"
    # A real `get --lease` marks the lease FIRST, does its work (TH_GET_DELAY models
    # how long a create-or-reset takes), and prints the path only at the END. So a
    # warmer killed mid-warm holds a lease it never saw.
    # A REAL POOL REUSES BEFORE IT CREATES: an available slot is handed back, and
    # only an empty pool costs a new one. That distinction is the whole point of
    # reclaiming a leaked lease, so the stub has to be able to express it.
    slot=""
    if [ -n "${TH_FREE_STATE:-}" ] && [ -s "$TH_FREE_STATE" ]; then
      slot=$(head -n 1 "$TH_FREE_STATE")
      rest=$(tail -n +2 "$TH_FREE_STATE")
      printf '%s' "${rest:+$rest
}" > "$TH_FREE_STATE"
    fi
    [ -n "$slot" ] || slot=${TH_NEW_SLOT:?}
    mkdir -p "$slot"
    printf '%s %s\n' "$slot" "$(holder_of "$@")" >> "${TH_LEASE_STATE:?}"
    # A user-level post_create hook runs INSIDE the get, before the worktree is
    # handed over - which is how a slot arrives already dirty on the box firstmate
    # runs on. Unset for every case that does not care.
    if [ -n "${TH_POST_CREATE:-}" ] && [ -x "$TH_POST_CREATE" ]; then
      ( cd "$slot" && "$TH_POST_CREATE" ) >/dev/null 2>&1 || true
    fi
    delay=$(cat "${TH_GET_DELAY:?}" 2>/dev/null || echo 0)
    [ "$delay" = 0 ] || sleep "$delay"
    printf '%s\n' "$slot"
    ;;
  return)
    # THE BUG THIS SUITE EXISTS TO PIN (treehouse v2.0.0, reproduced by hand
    # 2026-08-12): an UNFORCED return on a worktree with uncommitted tracked changes
    # prompts "Clean and return? [Y/n]", and with no terminal to answer it prints
    # `Aborted.`, releases NOTHING - and exits 0.
    forced=no; target=""
    shift
    for a in "$@"; do
      case "$a" in --force) forced=yes ;; -*) ;; *) target=$a ;; esac
    done
    if [ "$forced" = no ] && [ -n "$target" ] && [ -d "$target" ] \
       && [ -n "$(git -C "$target" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
      # On STDERR, where the real binary puts it (probed against treehouse v2.0.0,
      # 2026-08-12: `2>&1 >/dev/null` shows the prompt, `2>/dev/null` shows nothing).
      # That is the channel fm_pool_release captures for its FAILED line.
      printf 'Worktree has uncommitted changes. Clean and return? [Y/n] Aborted.\n' >&2
      exit 0
    fi
    # TH_RETURN_NOOP models a return that reports success and frees nothing for some
    # OTHER reason - the class the exit code can never be trusted to reveal.
    [ "${TH_RETURN_NOOP:-0}" = 1 ] && exit 0
    # And it frees THE SLOT IT WAS GIVEN, not "the lease": a return aimed at the
    # wrong path must leave the right one standing, or no test can see the
    # difference.
    if [ -f "${TH_LEASE_STATE:?}" ]; then
      if grep -qF -- "$target " "$TH_LEASE_STATE"; then
        # TH_FREE_SINK: the lease really goes, but the slot does NOT come back as
        # available - treehouse left it dirty, or a crew's plain `get` took it in the
        # gap. Same observable state, and the case a released slot cannot be assumed
        # to be a free one.
        [ -n "${TH_FREE_STATE:-}" ] && [ "${TH_FREE_SINK:-0}" != 1 ] \
          && printf '%s\n' "$target" >> "$TH_FREE_STATE"
      fi
      [ "${TH_BREAK_STATUS_ON_RETURN:-0}" = 1 ] && : > "${TH_STATUS_BREAK:?}"
      kept=$(grep -vF -- "$target " "$TH_LEASE_STATE" || true)
      printf '%s' "${kept:+$kept
}" > "$TH_LEASE_STATE"
    fi
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  printf '%s\n' "$case_dir"
}

# A meta puts the project "in flight", which is what makes it eligible for a spare.
in_flight() {  # <case-dir> [kind]
  fm_write_meta "$1/home/state/t1.meta" \
    "window=firstmate:fm-t1" \
    "worktree=$1/wt" \
    "project=$1/proj" \
    "kind=${2:-ship}"
}

warm_env() {  # <case-dir> -> the env every warm run shares
  local case_dir=$1
  printf '%s\n' \
    "PATH=$case_dir/fakebin:$PATH" \
    "TH_LOG=$case_dir/th.log" \
    "TH_STATUS=$case_dir/status.txt" \
    "TH_GET_RC=$case_dir/get-rc" \
    "TH_GET_DELAY=$case_dir/get-delay" \
    "TH_LEASE_STATE=$case_dir/lease-state" \
    "TH_FREE_STATE=$case_dir/free-state" \
    "TH_STATUS_BREAK=$case_dir/status-broken" \
    "TH_NEW_SLOT=$case_dir/th-root/pool/9/proj" \
    "FM_ROOT_OVERRIDE=$ROOT" \
    "FM_HOME=$case_dir/home" \
    "FM_STATE_OVERRIDE=$case_dir/home/state" \
    "FM_CONFIG_OVERRIDE=$case_dir/home/config" \
    "FM_PROJECTS_OVERRIDE=$case_dir/home/projects" \
    "FM_TREEHOUSE_ROOT=$case_dir/th-root"
}

run_warm() {  # <case-dir> [args...]
  local case_dir=$1; shift
  local -a e=()
  while IFS= read -r kv; do e+=("$kv"); done < <(warm_env "$case_dir")
  ( cd "$case_dir" || exit 1; env "${e[@]}" "$WARM" "$@" )
}

# Start a warm in the BACKGROUND and set WARM_PID, so a test can kill it
# mid-install. NOT `pid=$(run_warm_bg)`: a background job started inside a command
# substitution inherits its stdout pipe, so the substitution would block until the
# warm exits - and the job would be a child of the substitution's subshell, not of
# this shell, so kill/wait would not reach it. Hence a global, and streams closed.
run_warm_bg() {  # <case-dir>
  local case_dir=$1
  local -a e=()
  while IFS= read -r kv; do e+=("$kv"); done < <(warm_env "$case_dir")
  ( cd "$case_dir" || exit 1; exec env "${e[@]}" "$WARM" ) >/dev/null 2>&1 &
  WARM_PID=$!
}

pool_key() {  # <case-dir> -> the pool lock key for its project
  local real
  real=$(cd "$1/proj" && pwd -P)
  printf 'proj-%s' "$(printf '%s' "$real" | cksum | awk '{print $1}')"
}

# The boot id this box is on NOW. A lock is only honored as live when its pid is
# alive AND it was recorded on THIS boot - see fm_pool_owner_alive.
current_boot() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    tr -d '[:space:]' < /proc/sys/kernel/random/boot_id
  elif [ -r /proc/stat ] && grep -q '^btime' /proc/stat 2>/dev/null; then
    sed -n 's/^btime[[:space:]]*//p' /proc/stat | head -n 1 | tr -d '[:space:]'
  else
    printf 'no-boot-id'
  fi
}

# hold_lock_live <case-dir>: hold the pool lock the way a REAL warmer does ON THIS
# BOX, and set LOCK_HOLDER_PID.
#
# Which way that is depends on the platform, because fm_pool_lock_acquire itself
# branches: flock where it exists (CI, Linux), a pid+boot directory where it does
# not (stock macOS ships no flock). Hardcoding flock here made cases (f) and (g)
# fail on every macOS box with `flock: command not found` - not a real defect, but
# a local suite that cannot run is a local suite nobody trusts.
#
# Neither branch plants a lock by hand. Under flock the kernel is the arbiter, so
# a hand-planted directory would not exclude anything; under the fallback the lock
# records the OWNER'S PID, so it has to be a process we actually hold and can kill
# to simulate a crash. Both branches therefore hold a real live process.
hold_lock_live() {
  local base i=0
  base="$1/th-root/.fm-warm-locks/$(pool_key "$1")"
  mkdir -p "$(dirname "$base")"

  if command -v flock >/dev/null 2>&1; then
    # `exec sleep` so the process that HOLDS fd 9 is the one whose pid we record:
    # a plain `flock -c 'sleep'` leaves an orphan child that INHERITED the fd and so
    # keeps the lock after the recorded pid is killed.
    ( flock -x 9; exec sleep 60 ) 9>"$base.lock" &
    LOCK_HOLDER_PID=$!
    while [ "$i" -lt 40 ]; do          # wait until the lock is really held
      flock -n "$base.lock" -c true 2>/dev/null || return 0
      sleep 0.1; i=$((i + 1))
    done
    return 1
  fi

  # Fallback path: take the lock through the library, in its OWN bash process, so
  # the pid the lock records is the pid we hold. `exec sleep` for the same reason
  # as above - the recorded pid must be the one that stays alive.
  bash -c '. "$1"; fm_pool_lock_acquire "$2" || exit 1; exec sleep 60' \
    _ "$ROOT/bin/fm-pool-lib.sh" "$base" &
  LOCK_HOLDER_PID=$!
  while [ "$i" -lt 40 ]; do            # wait until the lock directory is really there
    [ -r "$base/pid" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

release_lock_holder() {
  [ -n "${LOCK_HOLDER_PID:-}" ] || return 0
  kill "$LOCK_HOLDER_PID" 2>/dev/null
  wait "$LOCK_HOLDER_PID" 2>/dev/null
  LOCK_HOLDER_PID=""
}

# plant_dir_lock <case-dir> <pid> <boot>: plant a DIRECTORY lock, for the fallback
# path (no flock). That path must reclaim a stale lock, and must not trust a bare
# pid across a reboot.
plant_dir_lock() {
  local lock
  lock="$1/th-root/.fm-warm-locks/$(pool_key "$1")"
  mkdir -p "$lock"
  printf '%s\n' "$2" > "$lock/pid"
  printf '%s\n' "$3" > "$lock/boot"
}

lease_state() { [ -s "$1/lease-state" ] && printf 'leased' || printf 'free'; }
leases() { cat "$1/lease-state" 2>/dev/null || true; }
th_log() { cat "$1/th.log"; }
warm_log() { cat "$1/home/state/.pool-warm.log" 2>/dev/null || true; }

# --- (a) a free warm slot exists: warm nothing --------------------------------
C=$(new_case a)
in_flight "$C"
cat > "$C/status.txt" <<'EOF'
1     in-use       /pool/1/proj
2     available    /pool/2/proj
EOF
run_warm "$C" || fail "(a) must exit 0"
assert_not_contains "$(th_log "$C")" "get" "(a) a pool with a free warm slot must not be grown"
pass "(a) a free warm slot already waiting means no warming at all"

# --- (b) no free slot: provision one preventively -----------------------------
C=$(new_case b)
in_flight "$C"
cat > "$C/status.txt" <<'EOF'
1     in-use       /pool/1/proj
2     in-use       /pool/2/proj
EOF
run_warm "$C" || fail "(b) must exit 0"
log=$(th_log "$C")
assert_contains "$log" "get --lease --lease-holder fm-warm-proj" "(b) warming IS treehouse get --lease"
assert_contains "$log" "return" "(b) the lease must be released so the slot is available"
assert_contains "$(warm_log "$C")" "WARMED" "(b) a successful warm is logged"
pass "(b) with every slot busy, the next one is provisioned preventively"

# --- (c) the lease covers the whole install, and the RETURN names that slot ----
# The lease is what stops a crew being handed a half-installed slot: it must be
# taken before the install and released only after, on the very path it leased.
C=$(new_case c)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
run_warm "$C" || fail "(c) must exit 0"
log=$(th_log "$C")
assert_contains "$log" "get --lease" "(c) the slot is leased for the install"
assert_contains "$log" "return --force $C/th-root/pool/9/proj" "(c) the lease is released on the leased path"
[ "$(printf '%s\n' "$log" | grep -c '^treehouse get')" = 1 ] || fail "(c) exactly one slot must be warmed per cycle"
pass "(c) the lease is held across the install and released on the leased slot"

# --- (d) the disk budget stops warming, with real numbers ---------------------
# optiroq is ~2.8 GB/slot and firstmate ~6 MB/slot, so the ceiling is DISK, not a
# slot count. Two ~1 MB slots and a 2.5 MB budget: the next slot would not fit.
#
# NOT a 3 MB budget, which is what this used to use. `du -sk` reports exactly 2048
# for these two slots on APFS, so the projection (2048 used + 1024 estimated) came
# to exactly 3072 - and the ceiling allows a slot that fits EXACTLY, so nothing was
# blocked and this case failed. It passed only on filesystems that charge for
# directory blocks and pushed `du` over the line. Pick a budget the projection
# clears unambiguously, so the case tests the ceiling and not the block size.
C=$(new_case d)
in_flight "$C"
mkdir -p "$C/th-root/pool/1" "$C/th-root/pool/2"
dd if=/dev/zero of="$C/th-root/pool/1/blob" bs=1024 count=1024 status=none
dd if=/dev/zero of="$C/th-root/pool/2/blob" bs=1024 count=1024 status=none
cat > "$C/status.txt" <<EOF
1     in-use       $C/th-root/pool/1/proj
2     in-use       $C/th-root/pool/2/proj
EOF
FM_POOL_DISK_BUDGET_KB=2560 run_warm "$C" || fail "(d) must exit 0"
assert_not_contains "$(th_log "$C")" "get" "(d) a budget-blocked pool must NOT be grown"
blocked=$(warm_log "$C")
assert_contains "$blocked" "disk budget reached" "(d) the budget block must be reported"
assert_contains "$blocked" "GB" "(d) it must report the real numbers"
assert_contains "$blocked" "FM_POOL_DISK_BUDGET_GB" "(d) it must name the knob"
pass "(d) the disk budget stops warming and reports the real numbers"

# The report is made ONCE: an unchanged situation must not re-log every cycle.
before=$(warm_log "$C" | grep -c 'disk budget reached')
FM_POOL_DISK_BUDGET_KB=2560 run_warm "$C" || fail "(d2) must exit 0"
after=$(warm_log "$C" | grep -c 'disk budget reached')
[ "$before" = "$after" ] || fail "(d2) a blocked warm must be reported once, not every cycle"
pass "(d2) an unchanged block is reported once, not on every cycle"

# --- (e) treehouse's own max_trees stops warming ------------------------------
C=$(new_case e)
in_flight "$C"
printf 'max_trees = 2\n' > "$C/proj/treehouse.toml"
cat > "$C/status.txt" <<'EOF'
1     in-use       /pool/1/proj
2     in-use       /pool/2/proj
EOF
run_warm "$C" || fail "(e) must exit 0"
assert_not_contains "$(th_log "$C")" "get" "(e) max_trees must be respected"
assert_contains "$(warm_log "$C")" "max_trees" "(e) the max_trees block must be reported"
pass "(e) treehouse's own max_trees ceiling is respected"

# --- (f) single warmer per pool ----------------------------------------------
# Two warmers racing would over-provision by GBs. A live lock owner wins.
C=$(new_case f)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
hold_lock_live "$C" || fail "(f) setup: could not hold the pool lock"
run_warm "$C" || fail "(f) must exit 0"
assert_not_contains "$(th_log "$C")" "get" "(f) a second warmer must not warm a pool another owns"
pass "(f) exactly one warmer acts per pool - a live lock holder wins"

# --- (g) the lock is POOL-scoped, not home-scoped -----------------------------
# Secondmate homes share pools. A home-scoped lock would let two homes warm the
# same pool at once. The lock above was taken with no firstmate home at all, and
# a DIFFERENT home pointing at the same project must still be excluded by it.
run_warm_from_other_home() {  # <case-dir>
  local case_dir=$1
  mkdir -p "$case_dir/home2/state" "$case_dir/home2/config"
  cp "$case_dir/home/state/t1.meta" "$case_dir/home2/state/t1.meta"
  ( cd "$case_dir" || exit 1
    env PATH="$case_dir/fakebin:$PATH" \
      TH_LOG="$case_dir/th.log" TH_STATUS="$case_dir/status.txt" \
      TH_GET_RC="$case_dir/get-rc" TH_NEW_SLOT="$case_dir/th-root/pool/9/proj" \
      FM_ROOT_OVERRIDE="$ROOT" \
      FM_HOME="$case_dir/home2" \
      FM_STATE_OVERRIDE="$case_dir/home2/state" \
      FM_CONFIG_OVERRIDE="$case_dir/home2/config" \
      FM_PROJECTS_OVERRIDE="$case_dir/home2/projects" \
      FM_TREEHOUSE_ROOT="$case_dir/th-root" \
      "$WARM" )
}
run_warm_from_other_home "$C" || fail "(g) must exit 0"
assert_not_contains "$(th_log "$C")" "get" "(g) a SECOND HOME must contend for the same pool lock"
release_lock_holder    # the live warmer this pool was locked by is done
pass "(g) the lock is scoped to the pool, so two homes never warm one pool twice"

# --- (h) a failed treehouse get breaks nothing -------------------------------
C=$(new_case h)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
printf '1\n' > "$C/get-rc"             # treehouse get fails
run_warm "$C" || fail "(h) a failed warm must still exit 0 - it must never break a spawn"
assert_contains "$(warm_log "$C")" "FAILED" "(h) the failure must be logged"
assert_absent "$C/th-root/.fm-warm-locks/$(pool_key "$C")" "(h) a failed warm must not leave the pool lock held"
pass "(h) a failed warm logs, retires quietly, and leaves no lock behind"

# --- (i) an idle fleet warms nothing -----------------------------------------
C=$(new_case i)                        # no meta: nothing in flight
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
run_warm "$C" || fail "(i) must exit 0"
assert_not_contains "$(th_log "$C")" "get" "(i) a project with no work in flight needs no spare"
pass "(i) an idle fleet warms nothing"

# --- (k) a warmer KILLED mid-install must not leak the treehouse lease ---------
# The permanent one. treehouse: "A leased worktree is never handed out by a later
# get and never removed by prune ... until you release it." So a warmer killed
# during the install (this box rebooted 8 times in a day) takes a pool slot out of
# circulation FOREVER - its GBs still counted against the disk budget. bash runs
# the EXIT trap on SIGTERM, so a graceful reboot IS a cleanup opportunity.
C=$(new_case k)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
printf '6\n' > "$C/get-delay"           # long enough to be killed mid-install; no longer
run_warm_bg "$C"; pid=$WARM_PID
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(lease_state "$C")" = leased ] && break
  sleep 0.3
done
[ "$(lease_state "$C")" = leased ] || fail "(k) setup: the warmer should hold a lease by now"
kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
[ "$(lease_state "$C")" = free ] \
  || fail "(k) a warmer killed mid-install LEAKED its lease - that slot is gone from the pool forever"
assert_contains "$(th_log "$C")" "return" "(k) the trap must return the leased slot to treehouse"
assert_absent "$C/th-root/.fm-warm-locks/$(pool_key "$C")" "(k) and must not leave the pool lock held"
pass "(k) a warmer killed mid-install releases its lease - the slot is not lost forever"

# --- (l) a HUNG install must be bounded --------------------------------------
# Unbounded, a hung post_create holds the pool lock WITH A LIVE PID (so no other
# warmer may ever reclaim it) AND the lease (so the slot is gone) AND suppresses
# its own leak report (warmer_is_live() sees the live pid). Permanent and invisible.
C=$(new_case l)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
printf '10\n' > "$C/get-delay"          # hangs well past the timeout below
start=$(date +%s)
FM_POOL_WARM_TIMEOUT=2 run_warm "$C" || fail "(l) a bounded warm must still exit 0"
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 30 ] || fail "(l) the warm was not bounded: took ${elapsed}s"
assert_contains "$(warm_log "$C")" "timed out" "(l) the timeout must be reported"
[ "$(lease_state "$C")" = free ] \
  || fail "(l) a timed-out warm must still release its lease"
assert_absent "$C/th-root/.fm-warm-locks/$(pool_key "$C")" "(l) and must not hold the pool lock forever"
pass "(l) a hung install is bounded, its lease released and its lock freed"

# --- (o) the bound must hold on a box with no `timeout` binary ------------------
# fm_pool_run_bounded is what makes (l) true. Stock macOS ships no `timeout`, and
# the callers used to degrade to an UNBOUNDED run there - so on the box firstmate
# actually runs on, (l)'s guarantee quietly did not hold. CI is Linux, where the
# fallback would never execute on its own, so force it with a PATH that has no
# `timeout` on it.
NOBIN="$TMP_ROOT/o/nobin"
mkdir -p "$NOBIN"
ln -sf "$(command -v sleep)" "$NOBIN/sleep"
start=$(date +%s)
rc=0
# shellcheck source=bin/fm-pool-lib.sh disable=SC1091
( PATH="$NOBIN"; . "$ROOT/bin/fm-pool-lib.sh"; fm_pool_run_bounded 2 sleep 60 ) || rc=$?
elapsed=$(( $(date +%s) - start ))
expect_code 124 "$rc" "(o) an expired bound must report 124, exactly as timeout does"
[ "$elapsed" -lt 30 ] || fail "(o) the fallback bound never fired: took ${elapsed}s"
rc=0
( PATH="$NOBIN"; . "$ROOT/bin/fm-pool-lib.sh"; fm_pool_run_bounded 30 sleep 0 ) || rc=$?
expect_code 0 "$rc" "(o) a command that finishes in time keeps its own exit status"
pass "(o) the time bound holds, and reports 124, with no timeout binary on the box"

# --- (p) the warm is what makes a warm slot warm ------------------------------
# treehouse hands over an EMPTY worktree and installs nothing, so without this step
# "warmed" would mean no more than "created" and the first crew would still pay the
# whole install. It has to happen while the lease is still held, and it has to
# inherit the warm's own deadline, or a three-root project could hold that lease
# for three times the bound the warm was given.
C=$(new_case p)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
SLOT="$C/th-root/pool/9/proj"
mkdir -p "$SLOT"
printf '{"name":"proj"}\n' > "$SLOT/package.json"
cat > "$C/fakebin/npm" <<SH
#!/usr/bin/env bash
d=none; [ -n "\${FM_PROVISION_DEADLINE:-}" ] && d=set
printf 'cwd=%s deadline=%s\n' "\$PWD" "\$d" >> "$C/npm.log"
mkdir -p node_modules/pkg && printf 'x\n' > node_modules/pkg/index.js
exit 0
SH
chmod +x "$C/fakebin/npm"
: > "$C/npm.log"
run_warm "$C" || fail "(p) must exit 0"
# The path is matched by its pool-relative tail: the provisioner reports RESOLVED
# paths, and on macOS this tmpdir sits under a symlinked /var.
assert_grep "/pool/9/proj deadline=set" "$C/npm.log" \
  "(p) the leased slot is provisioned, under the warm's own deadline"
assert_contains "$(warm_log "$C")" "PROVISION proj" "(p) and the step is reported in the warm log"
assert_contains "$(th_log "$C")" "return" "(p) the lease is still released afterwards"
pass "(p) the warm provisions the slot it leased, under its own time budget"

# --- (q) a slot whose install FAILED is not a warm slot -----------------------
# The provision step's status must reach this log. Before that step existed, an
# install failure surfaced through the `treehouse get` rc as `FAILED <name>`; a warm
# that discards the provisioner's status leaves a permanently failing install
# invisible in the only place it is recorded, and tells the disk-budget rail the
# warm succeeded. A cold slot is survivable; calling it warm is not.
C=$(new_case qcold)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
SLOT="$C/th-root/pool/9/proj"
mkdir -p "$SLOT"
printf '{"name":"proj"}\n' > "$SLOT/package.json"
cat > "$C/fakebin/npm" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$C/fakebin/npm"
run_warm "$C" || fail "(q) a failed install must still never fail the warm"
assert_contains "$(warm_log "$C")" "is free but COLD" "(q) the cold slot is named as cold"
assert_not_contains "$(warm_log "$C")" "WARMED proj" "(q) and is NOT reported as warm"
assert_contains "$(th_log "$C")" "return" "(q) the lease is released either way"
[ "$(lease_state "$C")" = free ] || fail "(q) a cold slot must still go back to the pool"
pass "(q) a slot whose install failed is logged COLD, never as warmed"

# --- (r) ONE deadline for the whole warm, taken BEFORE the lease --------------
# The pool lock is shared with every secondmate home pointing at this pool. A
# deadline computed AFTER `treehouse get` returned restarts the clock, so a slow get
# plus a full install budget holds that lock for up to twice the bound, blocking the
# other warmer for the whole doubled window.
C=$(new_case rdeadline)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
SLOT="$C/th-root/pool/9/proj"
mkdir -p "$SLOT"
printf '{"name":"proj"}\n' > "$SLOT/package.json"
printf '4\n' > "$C/get-delay"          # a `treehouse get` that takes real time
cat > "$C/fakebin/npm" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${FM_PROVISION_DEADLINE:-none}" > "$C/deadline"
mkdir -p node_modules/pkg && printf 'x\n' > node_modules/pkg/index.js
exit 0
SH
chmod +x "$C/fakebin/npm"
BEFORE=$(date +%s)
FM_POOL_WARM_TIMEOUT=20 run_warm "$C" || fail "(r) must exit 0"
DEADLINE=$(cat "$C/deadline")
case "$DEADLINE" in
  ''|*[!0-9]*) fail "(r) the provisioner got no deadline at all ('$DEADLINE')" ;;
esac
# 20s bound, a 4s get: taken before the lease this is ~20s out, taken after it ~24s.
[ "$((DEADLINE - BEFORE))" -le 21 ] \
  || fail "(r) the provision deadline is $((DEADLINE - BEFORE))s out on a 20s bound - the get's time was not counted against it"
pass "(r) the whole warm shares one deadline, so a slow get cannot double the lock hold"

# --- (s) the slot must come back CLEAN, end to end ----------------------------
# npm rewrites the lockfile it installs from, and that lockfile is TRACKED.
# treehouse's reset is `git clean -fd` - no -x, no checkout - so it cannot revert
# that edit: the slot returns `dirty`, treehouse skips it on every later get and
# refuses to prune it, and each warm retires one slot permanently. Case (p) could
# not see this, because its fake npm never touched a tracked file.
#
# The rewrite here is CRLF-only, under a repo that normalizes line endings -
# optiroq's real shape, and the one `git diff` reports as no change at all while
# `git status` still calls the slot modified (verified 2026-07-30). The plain
# content rewrite is covered by tests/fm-worktree-provision.test.sh (q).
C=$(new_case sclean)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
SLOT="$C/th-root/pool/9/proj"
mkdir -p "$SLOT"
printf '{"name":"proj"}\n' > "$SLOT/package.json"
printf '{\n  "lockfileVersion": 3\n}\n' > "$SLOT/package-lock.json"
printf 'node_modules/\n' > "$SLOT/.gitignore"
printf '* text=auto eol=lf\n' > "$SLOT/.gitattributes"
git -C "$SLOT" init -q
git -C "$SLOT" add -A
git -C "$SLOT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fixture
cat > "$C/fakebin/npm" <<'SH'
#!/usr/bin/env bash
if [ -f package-lock.json ]; then
  awk '{ printf "%s\r\n", $0 }' package-lock.json > .lock.crlf && mv .lock.crlf package-lock.json
fi
mkdir -p node_modules/pkg && printf 'x\n' > node_modules/pkg/index.js
exit 0
SH
chmod +x "$C/fakebin/npm"
run_warm "$C" || fail "(s) must exit 0"
assert_contains "$(warm_log "$C")" "WARMED proj" "(s) the slot really was warmed"
[ -f "$SLOT/node_modules/pkg/index.js" ] || fail "(s) the install did not run"
DIRTY=$(git -C "$SLOT" status --porcelain --untracked-files=no)
[ -z "$DIRTY" ] \
  || fail "(s) the warmed slot came back DIRTY ($DIRTY) - treehouse will skip it on every later get and refuse to prune it"
pass "(s) a warm whose installer rewrites a tracked file returns the slot clean"

# --- (m) five concurrent warmers must produce exactly ONE warm ----------------
# The lock exists to stop two warmers over-provisioning a pool by GBs. The earlier
# mkdir+pid lock lost this under a stale lock: both contenders judged the owner
# dead, A re-created the lock and started warming, and B then DELETED A's live lock
# and warmed too (a rename-based reclaim is no better - it targets the PATH, which
# by then holds A's new lock). flock has no such window: the kernel arbitrates, and
# releases on death.
C=$(new_case m)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
printf '1\n' > "$C/get-delay"           # long enough for the racers to overlap
pids=""
for _ in 1 2 3 4 5; do
  run_warm_bg "$C"; pids="$pids $WARM_PID"
done
for p in $pids; do wait "$p" 2>/dev/null; done
gets=$(grep -c '^treehouse get' "$C/th.log" || true)
[ "$gets" -le 1 ] || fail "(m) $gets warmers raced through the stale lock - the pool is over-provisioned"
pass "(m) five warmers contending for one stale lock produce exactly one warm"

# --- (n) liveness must survive a reboot: a recycled pid is not a live warmer ---
# The lock lives under ~/.treehouse and outlives a reboot. A bare `kill -0` on the
# recorded pid then reads an UNRELATED live process as "the warmer is still
# working": warming is wedged off forever AND the leaked lease is suppressed from
# the report. Identity must include the boot.
C=$(new_case n)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
plant_dir_lock "$C" "$$" a-previous-boot   # a LIVE pid, but recorded on a PREVIOUS boot
FM_POOL_LOCK_FORCE_DIR=1 run_warm "$C" || fail "(n) must exit 0"
assert_contains "$(th_log "$C")" "get --lease" "(n) a lock from a previous boot must be reclaimed, not honored forever"
pass "(n) a live pid from a previous boot is not a live warmer - the lock is reclaimed"

# --- (j) a stale pool lock is reclaimed --------------------------------------
# A warmer killed mid-install (a reboot) must not wedge the pool's warming forever.
C=$(new_case j)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
plant_dir_lock "$C" 999999 "$(current_boot)"   # a DEAD owner on this boot
FM_POOL_LOCK_FORCE_DIR=1 run_warm "$C" || fail "(j) must exit 0"
assert_contains "$(th_log "$C")" "get --lease" "(j) a stale lock must be reclaimed, not honored forever"
pass "(j) a pool lock whose owner is dead is reclaimed"

# --- (t) a DIRTY slot must be RELEASED, not merely reported as released --------
# The leak that cost 17 GB. An operator's treehouse post_create hook installs
# dependencies inside `treehouse get`, so the slot is already dirty when the
# provisioner snapshots it and correctly declines to restore work it did not make.
# `treehouse return` then prompts, finds no terminal, aborts - AND EXITS 0. The warm
# logged WARMED, availability never rose, and always-plus-one added another slot
# every cycle. Nothing but the lease state can catch this: the exit code is a lie.
C=$(new_case t)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
SLOT="$C/th-root/pool/9/proj"
mkdir -p "$SLOT"
printf 'node_modules/\n' > "$SLOT/.gitignore"
printf 'v1\n' > "$SLOT/hook-touched.txt"
git -C "$SLOT" init -q
git -C "$SLOT" add -A
git -C "$SLOT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fixture
cat > "$C/post-create.sh" <<'SH'
#!/usr/bin/env bash
printf 'v2\n' > hook-touched.txt      # a TRACKED file, dirtied before the handover
SH
chmod +x "$C/post-create.sh"
TH_POST_CREATE="$C/post-create.sh" run_warm "$C" || fail "(t) must exit 0"
[ -n "$(git -C "$SLOT" status --porcelain --untracked-files=no)" ] \
  || fail "(t) setup: the slot was not dirty at return time, so this case proves nothing"
[ "$(lease_state "$C")" = free ] \
  || fail "(t) the lease on a dirty slot survived the release - the slot is stranded and the pool will grow around it"
assert_contains "$(th_log "$C")" "return --force" "(t) the release must force, as every other treehouse return in this repo does"
assert_contains "$(warm_log "$C")" "WARMED proj" "(t) and the slot really is back in the pool"
pass "(t) a dirty slot's lease is really released, not just logged as released"

# --- (u) a release that frees nothing is a FAILURE, whatever it exits with -----
# --force fixes the known abort; it cannot promise there is no other. So the verdict
# is treehouse's own status, never the exit code, and this is the branch that says so.
C=$(new_case u)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
TH_RETURN_NOOP=1 run_warm "$C" || fail "(u) a failed release must still never break a spawn"
[ "$(lease_state "$C")" = leased ] || fail "(u) setup: the return was supposed to free nothing"
assert_contains "$(warm_log "$C")" "the slot is still LEASED" "(u) an unreleased slot must be reported as still leased"
assert_not_contains "$(warm_log "$C")" "WARMED proj" "(u) and must never be logged as a warm slot the pool can hand out"
pass "(u) a return that frees nothing is reported FAILED, not WARMED"

# --- (v) a leaked warm lease is RECLAIMED, not routed around ------------------
# The self-healing the pool lacked. A lease still held under this pool's own warm
# holder, while WE hold the pool lock, is provably an orphan - so release it and warm
# through the normal path, where the pool hands that same slot straight back. It runs
# BEFORE the ceilings on purpose: it adds no slot, and the real pool was already at
# its budget, where a ceiling-first order would have left the leak permanent.
#
# The fixture puts the leak on slot 8 and leaves 9 as the one a GROWING pool would
# create, so "reclaimed, not grown" is a directory that must not exist rather than a
# hopeful reading of the log.
C=$(new_case v)
in_flight "$C"
mkdir -p "$C/th-root/pool/1"
dd if=/dev/zero of="$C/th-root/pool/1/blob" bs=1024 count=1024 status=none
printf '1     in-use       %s/th-root/pool/1/proj\n' "$C" > "$C/status.txt"
SLOT="$C/th-root/pool/8/proj"
mkdir -p "$SLOT"
printf '%s fm-warm-proj\n' "$SLOT" > "$C/lease-state"   # a warm that ended without releasing
FM_POOL_DISK_BUDGET_KB=1024 run_warm "$C" || fail "(v) must exit 0"
assert_contains "$(warm_log "$C")" "REAP proj" "(v) the reclaim must be visible in the only log that records it"
assert_contains "$(th_log "$C")" "return --force $SLOT" "(v) the leaked lease is released, never warmed under a dead warm's reservation"
assert_contains "$(th_log "$C")" "get --lease --lease-holder fm-warm-proj" "(v) and the warm then takes that slot under a lease of its own"
if [ -d "$C/th-root/pool/9" ]; then
  fail "(v) the pool grew a slot instead of taking back the one it already had"
fi
[ "$(lease_state "$C")" = free ] || fail "(v) the leaked lease must end up released"
assert_contains "$(warm_log "$C")" "WARMED proj" "(v) the reclaimed slot is warmed, not just freed"
assert_not_contains "$(warm_log "$C")" "disk budget" "(v) a full pool must not block the one action that reclaims a slot instead of adding one"
pass "(v) a warm lease leaked by an earlier cycle is reclaimed instead of growing the pool"

# --- (w) a LIVE warmer's lease is never reaped --------------------------------
# The reaper's safety rests on the pool lock: a lease under this holder can only be
# an orphan because a live warmer would still hold that lock, and a second warmer
# never gets past it. Prove the rail, not the string comparison - hold the lock with
# a real live process and leave a lease standing under the same holder the reaper
# matches. Anything that returns it here would be stealing a slot mid-install.
C=$(new_case w)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
printf '%s/th-root/pool/9/proj fm-warm-proj\n' "$C" > "$C/lease-state"   # the live warmer's in-flight lease
hold_lock_live "$C" || fail "(w) setup: could not hold the pool lock"
run_warm "$C" || fail "(w) must exit 0"
release_lock_holder
assert_not_contains "$(th_log "$C")" "return" "(w) a live warmer's lease must never be released by another warmer"
assert_not_contains "$(th_log "$C")" "get" "(w) nor may the pool be grown behind its back"
[ "$(lease_state "$C")" = leased ] || fail "(w) the live warmer's lease was taken out from under it"
pass "(w) a lease held while a live warmer owns the pool lock is left alone"

# --- (x) a crew's lease is never reaped, nor another project's warm ------------
# The line AGENTS.md rail 3 draws. A crew holds its slot under its TASK ID, and a
# warm for a different project holds one under a different fm-warm-* holder. Neither
# is this warmer's to touch, so with no lease of its own to reuse it must fall back
# to growing the pool exactly as before - and never name either slot in any command.
C=$(new_case x)
in_flight "$C"
cat > "$C/status.txt" <<'EOF'
1     in-use       /pool/1/proj
2     leased       /pool/2/proj  (held by fix-login-k3)
3     leased       /pool/3/proj  (held by fm-warm-otherproject)
EOF
run_warm "$C" || fail "(x) must exit 0"
log=$(th_log "$C")
assert_contains "$log" "get --lease --lease-holder fm-warm-proj" "(x) with no lease of its own to reuse, the warmer provisions a new slot"
assert_not_contains "$log" "/pool/2/proj" "(x) a crew's leased slot must never be named by any command the warmer runs"
assert_not_contains "$log" "/pool/3/proj" "(x) nor another project's warm lease"
assert_not_contains "$(warm_log "$C")" "REAP" "(x) and neither may be reported as reusable"
pass "(x) a crew's lease and a foreign warm lease are both out of the reaper's reach"

# --- (y) one holder, several leaked leases: a release is judged PER SLOT ---------
# The state the real leak actually reached - six slots, one fm-warm-<name> holder.
# A verdict that asks "does this HOLDER still hold anything?" instead of "is THIS
# slot still leased?" calls a perfectly good release FAILED, and the retry then
# forces a path that is already back in the pool, where `treehouse get` can have
# handed it to a crew. So the reaped slot must be reported WARMED even though a
# sibling leak is still standing, and must be returned exactly once.
C=$(new_case y)
in_flight "$C"
printf '1     in-use       /pool/1/proj
' > "$C/status.txt"
SLOT="$C/th-root/pool/8/proj"
SIBLING="$C/th-root/pool/9/proj"
mkdir -p "$SLOT" "$SIBLING"
printf '%s fm-warm-proj
%s fm-warm-proj
' "$SLOT" "$SIBLING" > "$C/lease-state"
run_warm "$C" || fail "(y) must exit 0"
assert_contains "$(warm_log "$C")" "WARMED proj" "(y) the slot whose lease really was released must be reported as warm"
assert_not_contains "$(warm_log "$C")" "still LEASED" "(y) a sibling leak under the same holder must not make this release look failed"
assert_not_contains "$(warm_log "$C")" "LEAKED" "(y) nor may the trap fire on a slot that is already back in the pool"
assert_not_contains "$(warm_log "$C")" "could not reclaim" "(y) a sibling leak under the same holder must not make the reclaim look failed either"
assert_not_contains "$(th_log "$C")" "return --force $SIBLING" "(y) and the sibling is not this cycle's to force - it is reclaimed by the cycle that needs it"
assert_contains "$(leases "$C")" "$SIBLING fm-warm-proj" "(y) setup: the sibling leak is what the next cycle reclaims"
pass "(y) with several leaks under one holder, each release is judged on its own slot"

# --- (z) a reclaim that cannot free its slot falls through to growing the pool --
# The starvation this design has to avoid. If the release keeps failing - a slot git
# can no longer return - a reaper that only ever retried it would leave the project
# with NO warm slot for as long as the leak lasts. So a failed reclaim is logged and
# the cycle provisions a slot anyway. TH_RETURN_NOOP frees nothing at all here, so
# the warm's own release fails too and it correctly declines to report WARMED; what
# this case pins is that the pool still got its slot.
C=$(new_case z)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
SLOT="$C/th-root/pool/8/proj"
mkdir -p "$SLOT"
printf '%s fm-warm-proj\n' "$SLOT" > "$C/lease-state"
TH_RETURN_NOOP=1 run_warm "$C" || fail "(z) must exit 0"
assert_contains "$(warm_log "$C")" "could not reclaim" "(z) an unreclaimable leak must be reported, not retried in silence"
assert_contains "$(th_log "$C")" "get --lease --lease-holder fm-warm-proj" "(z) and the project must still get a warm slot"
[ -d "$C/th-root/pool/9" ] || fail "(z) the cycle stalled on the leak instead of provisioning beside it"
pass "(z) a reclaim that cannot free its slot grows the pool rather than starving the project"

# --- (aa) a released slot is not assumed to be a free one ---------------------
# Reclaiming skips both ceilings, and it may do that only because the slot it freed
# is the one `treehouse get` hands back. Nothing guarantees that: treehouse can leave
# the slot dirty, and a crew takes slots with a plain `treehouse get` while holding no
# pool lock, so it can consume this one in the gap. Then the `get` CREATES a slot -
# and a creation that skipped the disk budget is the outcome this whole branch exists
# to end. So the skip is earned by re-reading the pool, not assumed from the release.
C=$(new_case aa)
in_flight "$C"
mkdir -p "$C/th-root/pool/1"
dd if=/dev/zero of="$C/th-root/pool/1/blob" bs=1024 count=1024 status=none
printf '1     in-use       %s/th-root/pool/1/proj\n' "$C" > "$C/status.txt"
SLOT="$C/th-root/pool/8/proj"
mkdir -p "$SLOT"
printf '%s fm-warm-proj\n' "$SLOT" > "$C/lease-state"
TH_FREE_SINK=1 FM_POOL_DISK_BUDGET_KB=1024 run_warm "$C" || fail "(aa) must exit 0"
assert_contains "$(warm_log "$C")" "REAP proj" "(aa) setup: the leaked lease is still released"
assert_contains "$(warm_log "$C")" "not free to take" "(aa) a release that left no free slot must be reported, not silently treated as one"
assert_contains "$(warm_log "$C")" "disk budget" "(aa) and the budget must decide the slot that would then be CREATED"
assert_not_contains "$(th_log "$C")" "treehouse get" "(aa) a pool over its budget must not grow just because a reclaim ran first"
pass "(aa) a reclaim that leaves no free slot falls back under the ceilings"

# --- (ab) a release that cannot be VERIFIED is a failure, not a success --------
# The verdict is a `treehouse status` read, so the one thing that can defeat it is a
# pool treehouse can no longer describe. Answering "released" there is how this bug
# hid for a month; answering "still leased" leaves a slot the next cycle reclaims. So
# it fails closed AND says why - a bare "still LEASED" with no reason is what sent a
# captain looking for crashed processes that never existed.
C=$(new_case ab)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
TH_BREAK_STATUS_ON_RETURN=1 run_warm "$C" || fail "(ab) an unverifiable release must still never break a spawn"
assert_contains "$(warm_log "$C")" "still LEASED" "(ab) a release that cannot be verified must be reported as unreleased"
assert_contains "$(warm_log "$C")" "unreadable" "(ab) and must name the reason, or the log sends its reader hunting the wrong cause"
assert_not_contains "$(warm_log "$C")" "WARMED proj" "(ab) an unverified slot is never announced as one the pool can hand out"
pass "(ab) a release the pool cannot confirm is failed closed, with its reason named"
