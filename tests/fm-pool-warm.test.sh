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

  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'treehouse'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${TH_LOG:?}"
case "${1:-}" in
  status) cat "${TH_STATUS:?}" ;;
  get)
    rc=$(cat "${TH_GET_RC:?}")
    [ "$rc" = 0 ] || exit "$rc"
    # A real `get --lease` creates-or-resets the slot, runs post_create (the dep
    # install), and prints ONLY the path on stdout.
    mkdir -p "${TH_NEW_SLOT:?}"
    printf '%s\n' "$TH_NEW_SLOT"
    ;;
  return) ;;
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

run_warm() {  # <case-dir> [args...]
  local case_dir=$1; shift
  ( cd "$case_dir" || exit 1
    env PATH="$case_dir/fakebin:$PATH" \
      TH_LOG="$case_dir/th.log" \
      TH_STATUS="$case_dir/status.txt" \
      TH_GET_RC="$case_dir/get-rc" \
      TH_NEW_SLOT="$case_dir/th-root/pool/9/proj" \
      FM_ROOT_OVERRIDE="$ROOT" \
      FM_HOME="$case_dir/home" \
      FM_STATE_OVERRIDE="$case_dir/home/state" \
      FM_CONFIG_OVERRIDE="$case_dir/home/config" \
      FM_PROJECTS_OVERRIDE="$case_dir/home/projects" \
      FM_TREEHOUSE_ROOT="$case_dir/th-root" \
      "$WARM" "$@" )
}

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
key=$(printf '%s' "$(cd "$C/proj" && pwd -P)" | cksum | awk '{print $1}')
lock="$C/th-root/.fm-warm-locks/proj-$key"
mkdir -p "$lock"
printf '%s\n' "$$" > "$lock/pid"       # a LIVE owner (this test process)
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
pass "(g) the lock is scoped to the pool, so two homes never warm one pool twice"

# --- (h) a failed treehouse get breaks nothing -------------------------------
C=$(new_case h)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
printf '1\n' > "$C/get-rc"             # treehouse get fails
run_warm "$C" || fail "(h) a failed warm must still exit 0 - it must never break a spawn"
assert_contains "$(warm_log "$C")" "FAILED" "(h) the failure must be logged"
key=$(printf '%s' "$(cd "$C/proj" && pwd -P)" | cksum | awk '{print $1}')
assert_absent "$C/th-root/.fm-warm-locks/proj-$key" "(h) a failed warm must not leave the pool lock held"
pass "(h) a failed warm logs, retires quietly, and leaves no lock behind"

# --- (i) an idle fleet warms nothing -----------------------------------------
C=$(new_case i)                        # no meta: nothing in flight
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
run_warm "$C" || fail "(i) must exit 0"
assert_not_contains "$(th_log "$C")" "get" "(i) a project with no work in flight needs no spare"
pass "(i) an idle fleet warms nothing"

# --- (j) a stale pool lock is reclaimed --------------------------------------
# A warmer killed mid-install (a reboot) must not wedge the pool's warming forever.
C=$(new_case j)
in_flight "$C"
printf '1     in-use       /pool/1/proj\n' > "$C/status.txt"
key=$(printf '%s' "$(cd "$C/proj" && pwd -P)" | cksum | awk '{print $1}')
lock="$C/th-root/.fm-warm-locks/proj-$key"
mkdir -p "$lock"
printf '999999\n' > "$lock/pid"        # a DEAD owner
run_warm "$C" || fail "(j) must exit 0"
assert_contains "$(th_log "$C")" "get --lease" "(j) a stale lock must be reclaimed, not honored forever"
pass "(j) a pool lock whose owner is dead is reclaimed"
