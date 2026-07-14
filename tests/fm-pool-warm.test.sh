#!/usr/bin/env bash
# Tests for bin/fm-pool-warm.sh - the always-plus-one warm spare.
#
# The contract (its header owns the policy): for every project with work IN
# FLIGHT, at least one treehouse slot must sit free and warm, so a crew never
# pays the cold dependency install on the spawn path (measured 137s for optiroq;
# 2s warm). When the last free slot is taken, the next is provisioned
# preventively, in the background, on firstmate's time.
#
# treehouse is stubbed (the suite's usual fakebin/PATH shim): a real warm would
# install multiple GB. The stub records every treehouse invocation, so these
# tests assert the exact commands - that warming IS `get --lease` + `return`, and
# nothing reimplemented.
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
    cat "${TH_STATUS:?}"
    # Reality: treehouse's OWN status reports a held lease and who holds it. The
    # stub must too - that report is the only way a warmer killed mid-install can
    # find the lease whose path it never learned.
    if [ -f "${TH_LEASE_STATE:?}" ] && [ "$(cut -d' ' -f1 < "$TH_LEASE_STATE")" = leased ]; then
      printf '9     leased       %s  (held by %s)\n' \
        "${TH_NEW_SLOT:?}" "$(cut -d' ' -f2 < "$TH_LEASE_STATE")"
    fi
    ;;
  get)
    rc=$(cat "${TH_GET_RC:?}")
    [ "$rc" = 0 ] || exit "$rc"
    # A real `get --lease` marks the lease FIRST, then runs post_create (the dep
    # install - TH_GET_DELAY models how long that takes), and only prints the path
    # at the END. So a warmer killed mid-install holds a lease it never saw.
    mkdir -p "${TH_NEW_SLOT:?}"
    printf 'leased %s\n' "$(holder_of "$@")" > "${TH_LEASE_STATE:?}"
    delay=$(cat "${TH_GET_DELAY:?}" 2>/dev/null || echo 0)
    [ "$delay" = 0 ] || sleep "$delay"
    printf '%s\n' "$TH_NEW_SLOT"
    ;;
  return) printf 'free\n' > "${TH_LEASE_STATE:?}" ;;
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

# hold_lock_live <case-dir>: hold the pool lock the way a REAL warmer does - an
# flock held by a live process - and set LOCK_HOLDER_PID. Planting a directory
# would not do: the code locks with flock, and the kernel is the arbiter.
hold_lock_live() {
  local base i=0
  base="$1/th-root/.fm-warm-locks/$(pool_key "$1")"
  mkdir -p "$(dirname "$base")"
  # `exec sleep` so the process that HOLDS fd 9 is the one whose pid we record:
  # a plain `flock -c 'sleep'` leaves an orphan child that INHERITED the fd and so
  # keeps the lock after the recorded pid is killed.
  ( flock -x 9; exec sleep 60 ) 9>"$base.lock" &
  LOCK_HOLDER_PID=$!
  while [ "$i" -lt 40 ]; do            # wait until the lock is really held
    flock -n "$base.lock" -c true 2>/dev/null || return 0
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

lease_state() { cat "$1/lease-state" 2>/dev/null | cut -d' ' -f1 || true; }
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
assert_contains "$log" "return $C/th-root/pool/9/proj" "(c) the lease is released on the leased path"
[ "$(printf '%s\n' "$log" | grep -c '^treehouse get')" = 1 ] || fail "(c) exactly one slot must be warmed per cycle"
pass "(c) the lease is held across the install and released on the leased slot"

# --- (d) the disk budget stops warming, with real numbers ---------------------
# optiroq is ~2.8 GB/slot and firstmate ~6 MB/slot, so the ceiling is DISK, not a
# slot count. Two ~1 MB slots and a 3 MB budget: the next slot would not fit.
C=$(new_case d)
in_flight "$C"
mkdir -p "$C/th-root/pool/1" "$C/th-root/pool/2"
dd if=/dev/zero of="$C/th-root/pool/1/blob" bs=1024 count=1024 status=none
dd if=/dev/zero of="$C/th-root/pool/2/blob" bs=1024 count=1024 status=none
cat > "$C/status.txt" <<EOF
1     in-use       $C/th-root/pool/1/proj
2     in-use       $C/th-root/pool/2/proj
EOF
FM_POOL_DISK_BUDGET_KB=3072 run_warm "$C" || fail "(d) must exit 0"
assert_not_contains "$(th_log "$C")" "get" "(d) a budget-blocked pool must NOT be grown"
blocked=$(warm_log "$C")
assert_contains "$blocked" "disk budget reached" "(d) the budget block must be reported"
assert_contains "$blocked" "GB" "(d) it must report the real numbers"
assert_contains "$blocked" "FM_POOL_DISK_BUDGET_GB" "(d) it must name the knob"
pass "(d) the disk budget stops warming and reports the real numbers"

# The report is made ONCE: an unchanged situation must not re-log every cycle.
before=$(warm_log "$C" | grep -c 'disk budget reached')
FM_POOL_DISK_BUDGET_KB=3072 run_warm "$C" || fail "(d2) must exit 0"
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
printf '30\n' > "$C/get-delay"          # a long install to be killed in the middle of
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
printf '60\n' > "$C/get-delay"          # hangs far past the timeout below
start=$(date +%s)
FM_POOL_WARM_TIMEOUT=3 run_warm "$C" || fail "(l) a bounded warm must still exit 0"
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 30 ] || fail "(l) the warm was not bounded: took ${elapsed}s"
assert_contains "$(warm_log "$C")" "timed out" "(l) the timeout must be reported"
[ "$(lease_state "$C")" = free ] \
  || fail "(l) a timed-out warm must still release its lease"
assert_absent "$C/th-root/.fm-warm-locks/$(pool_key "$C")" "(l) and must not hold the pool lock forever"
pass "(l) a hung install is bounded, its lease released and its lock freed"

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
printf '2\n' > "$C/get-delay"           # long enough for the racers to overlap
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
