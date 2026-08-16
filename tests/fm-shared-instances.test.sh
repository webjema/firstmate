#!/usr/bin/env bash
# Behavior tests for the shared-instance arrangement: several firstmate instances on
# one host sharing one checkout, one projects/ clone per repository and one worktree
# pool, each with a bare $FM_HOME. docs/configuration.md owns the arrangement.
#
# Every case here asserts one of the two things sharing changes: that what must stay
# PRIVATE to an instance still is (session lock, wake queue, per-task temp root), or
# that what is now CONTENDED actually contends (the warm lock's key, the per-clone
# write lock, the updater's refusal).
#
# Nothing touches a live home, a real clone or the operator's ~/.treehouse: every
# fixture is a scratch git repo, and tests/lib.sh redirects FM_PEER_CACHE_DIR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-shared-instances)
fm_git_identity

# Per-task temp roots live under /tmp by contract (bin/fm-peer-lib.sh), outside
# TMP_ROOT, so they are cleaned by id here. Own EXIT trap per tests/lib.sh.
shared_cleanup() {
  rm -rf /tmp/fm-*-sharedtmp-x1
  fm_test_cleanup
}
trap shared_cleanup EXIT

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
# harness_pid()/holder_alive() in fm-lock.sh walk `ps` looking for a harness command
# name; report every queried pid as a live claude so lock acquisition and the peer
# liveness re-check are deterministic rather than dependent on what launched the suite.
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"comm="*) printf '/usr/local/bin/claude\n'; exit 0 ;;
  *"args="*) printf 'claude\n'; exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/ps"

# wait_for_file <path>: block until a background holder signals it is holding. The
# bound is only there so a holder that died fails the test instead of hanging the
# suite, and it is deliberately far wider than the work it waits on (a flock and a
# touch): a bound tight enough for a loaded parallel run to lose is what puts a test
# in bin/fm-test.sh's serial tail, and this suite has no reason to be there.
wait_for_file() {
  local f=$1 i=0
  while [ ! -e "$f" ]; do
    i=$((i + 1))
    [ "$i" -lt 1200 ] || fail "timed out waiting for $f"
    sleep 0.05
  done
}

# make_bare_home <name> [projects-dir]: a bare home built by the real
# fm-home-init.sh, so every case runs against the provisioning path rather than a
# hand-rolled imitation of it. Echoes the home path.
make_bare_home() {
  local name=$1 projects=${2:-$TMP_ROOT/shared-projects} home="$TMP_ROOT/$1"
  "$ROOT/bin/fm-home-init.sh" "$home" --projects "$projects" >/dev/null
  printf '%s\n' "$home"
}

# --- private: the session lock ----------------------------------------------

# Two instances over ONE checkout must each get their own lock. If they shared one,
# the second would be told to operate read-only, and the arrangement would be a
# single-instance arrangement with extra steps.
test_two_homes_take_independent_session_locks() {
  local a b out_a out_b before after shared_before shared_after
  a=$(make_bare_home lock-a)
  b=$(make_bare_home lock-b)
  before=$(git -C "$ROOT" status --porcelain)
  # The checkout's own state/.lock is SNAPSHOTTED, not asserted absent: this suite
  # runs from a live firstmate home, where that file exists by definition, and a
  # case that reads ambient state fails for a reason that has nothing to do with
  # what it asserts. What must hold is that neither instance touched it.
  shared_before=$(cat "$ROOT/state/.lock" 2>/dev/null || printf '<absent>')

  out_a=$(PATH="$FAKEBIN:$PATH" FM_HOME="$a" "$ROOT/bin/fm-lock.sh" 2>&1)
  out_b=$(PATH="$FAKEBIN:$PATH" FM_HOME="$b" "$ROOT/bin/fm-lock.sh" 2>&1)
  assert_contains "$out_a" "lock acquired" "the first instance did not get its lock"
  assert_contains "$out_b" "lock acquired" "the second instance was refused a lock it does not share"
  assert_present "$a/state/.lock" "the first instance's lock is not in its own home"
  assert_present "$b/state/.lock" "the second instance's lock is not in its own home"

  after=$(git -C "$ROOT" status --porcelain)
  [ "$before" = "$after" ] \
    || fail "running two instances changed the shared checkout's working tree"$'\n'"$after"
  shared_after=$(cat "$ROOT/state/.lock" 2>/dev/null || printf '<absent>')
  [ "$shared_before" = "$shared_after" ] \
    || fail "an instance wrote its session lock into the shared checkout's state/.lock"
  pass "two homes over one checkout take independent session locks and leave the checkout alone"
}

# --- private: the wake queue -------------------------------------------------

test_wake_queues_do_not_leak_between_homes() {
  local a b out_a out_b
  a=$(make_bare_home wake-a)
  b=$(make_bare_home wake-b)
  FM_HOME="$a" FM_STATE_OVERRIDE="$a/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_wake_append signal only-for-a "signal: only-for-a | task=only-for-a class=none"' \
    _ "$ROOT"

  out_b=$(FM_HOME="$b" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null || true)
  assert_not_contains "$out_b" "only-for-a" "one instance drained another instance's wake"
  out_a=$(FM_HOME="$a" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null || true)
  assert_contains "$out_a" "only-for-a" "the owning instance did not get its own wake back"
  pass "wake queues stay private to their home"
}

# --- contended: the warm-lock key -------------------------------------------

# make_shared_clone_pair <base>: two clones of ONE upstream, at different paths, with
# the SAME basename - the real arrangement, where each instance reaches the same
# repository through its own path. Echoes "<clone-a>|<clone-b>".
make_shared_clone_pair() {
  local seed="$TMP_ROOT/$1-seed" origin="$TMP_ROOT/$1-origin"
  local a="$TMP_ROOT/$1-a/proj" b="$TMP_ROOT/$1-b/proj"
  fm_git_init_commit "$seed"
  git clone --quiet --bare "$seed" "$origin"
  mkdir -p "$(dirname "$a")" "$(dirname "$b")"
  git clone --quiet "$origin" "$a"
  git clone --quiet "$origin" "$b"
  printf '%s|%s\n' "$a" "$b"
}

pool_key_of() {  # <clone>
  ( . "$ROOT/bin/fm-pool-lib.sh"; fm_pool_key "$1" )
}

# The defect this suite exists for. Two homes each holding a clone of one upstream
# addressed the SAME treehouse pool while deriving two DIFFERENT warm-lock keys, so
# they did not exclude each other at all and could both warm it. Keyed by the path,
# these two fixtures differ; keyed by the pool, they must not.
test_two_clones_of_one_upstream_derive_one_warm_lock_key() {
  local pair a b key_a key_b other key_other
  pair=$(make_shared_clone_pair warmkey)
  a=${pair%%|*}
  b=${pair##*|}
  key_a=$(pool_key_of "$a")
  key_b=$(pool_key_of "$b")
  [ -n "$key_a" ] || fail "fm_pool_key produced nothing"
  [ "$key_a" = "$key_b" ] \
    || fail "two clones of one upstream derive different warm-lock keys, so they cannot exclude each other: '$key_a' vs '$key_b'"

  # The key must still SEPARATE genuinely different pools, or the fix would be a lock
  # that serialises the whole box. Same basename, different upstream.
  other=$(make_shared_clone_pair otherkey)
  key_other=$(pool_key_of "${other%%|*}")
  [ "$key_a" != "$key_other" ] \
    || fail "clones of DIFFERENT upstreams collapsed onto one warm-lock key: $key_a"
  pass "two clones of one upstream derive one warm-lock key, and different upstreams stay apart"
}

# Deriving one key is only half of it: with two homes as two PROCESSES, the second
# must actually be kept out while the first holds the lock.
test_second_warmer_yields_to_the_first() {
  local pair a b base_a base_b marker peer_pid rc
  pair=$(make_shared_clone_pair warmlock)
  a=${pair%%|*}
  b=${pair##*|}
  base_a="$TMP_ROOT/warm-locks/$(pool_key_of "$a")"
  base_b="$TMP_ROOT/warm-locks/$(pool_key_of "$b")"
  marker="$TMP_ROOT/warmer-holding"

  # Instance A, warming through its own clone. It holds until the marker is removed,
  # so the lock is released on demand and no `sleep` is orphaned holding the fd.
  ( . "$ROOT/bin/fm-pool-lib.sh"
    fm_pool_lock_acquire "$base_a" || exit 1
    touch "$marker"
    while [ -e "$marker" ]; do sleep 0.1; done
    fm_pool_lock_release ) >/dev/null 2>&1 &
  peer_pid=$!
  wait_for_file "$marker"

  # Instance B, reaching the same pool through its own clone path.
  rc=0
  ( . "$ROOT/bin/fm-pool-lib.sh"; fm_pool_lock_acquire "$base_b" ) || rc=$?
  rm -f "$marker"
  wait "$peer_pid" 2>/dev/null || true

  [ "$rc" -ne 0 ] \
    || fail "a second warmer took the pool lock while the first held it, so two instances can warm one pool at once"
  pass "a second warmer on the same pool yields to the first"
}

# --- contended: the per-clone write lock ------------------------------------

clone_lock_path_of() {  # <clone>
  ( . "$ROOT/bin/fm-peer-lib.sh"; fm_clone_lock_path "$1" )
}

# Two spellings of one clone must reach one lock, or the mechanism is a no-op for
# exactly the instances it exists to serialise.
test_one_clone_reached_two_ways_takes_one_lock() {
  local real link p_real p_link
  real="$TMP_ROOT/lockpath/clone"
  mkdir -p "$real"
  ln -s "$TMP_ROOT/lockpath" "$TMP_ROOT/lockpath-link"
  link="$TMP_ROOT/lockpath-link/clone"
  p_real=$(clone_lock_path_of "$real")
  p_link=$(clone_lock_path_of "$link")
  [ "$p_real" = "$p_link" ] \
    || fail "one clone reached two ways took two locks: '$p_real' vs '$p_link'"
  pass "one clone reached through two spellings takes one write lock"
}

# build_sync_fixture <home> <name>: a home whose projects/<name> is a clone of an
# origin that has since moved on, so a fleet sync has real work to do. Echoes the
# clone path.
build_sync_fixture() {
  local home=$1 name=$2 seed="$TMP_ROOT/$2-seed" origin="$TMP_ROOT/$2-origin" branch
  fm_git_init_commit "$seed"
  git clone --quiet --bare "$seed" "$origin"
  mkdir -p "$home/projects"
  git clone --quiet "$origin" "$home/projects/$name"
  # Advance the origin so the clone is genuinely behind and a sync has work to do.
  printf 'moved on\n' >> "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" commit -qm second
  branch=$(git -C "$seed" symbolic-ref --short HEAD)
  git -C "$seed" push -q "$origin" "$branch"
  printf '%s\n' "$home/projects/$name"
}

# THE LIVENESS PROPERTY, and the one that was broken. Concurrent syncs on a shared
# clone were measured safe but LOSSY: git's own index.lock serialised them and the
# loser reported "skipped" and left its clone stale. The loser must now wait its turn
# and then do its work. The holder is deterministic rather than a second racing sync,
# so this cannot pass by winning a coin flip.
test_a_blocked_sync_waits_and_then_syncs() {
  local home clone lockpath marker peer_pid out t0 elapsed
  home=$(make_bare_home synclive "$TMP_ROOT/synclive-projects")
  clone=$(build_sync_fixture "$home" alpha)
  lockpath=$(clone_lock_path_of "$clone")
  mkdir -p "$(dirname "$lockpath")"
  marker="$TMP_ROOT/sync-holding"

  # A peer instance holding this clone's write lock, releasing after 3s. Redirected
  # away from this shell's stdout so the command substitution below cannot block on
  # a pipe the background process is still holding open.
  ( flock 9 && touch "$marker" && sleep 3 ) 9>"$lockpath" >/dev/null 2>&1 &
  peer_pid=$!
  wait_for_file "$marker"

  t0=$(date +%s)
  out=$(FM_HOME="$home" FM_PROJECTS_OVERRIDE="$home/projects" \
        FM_GRAPH_REINDEX_MODE=off FM_CLONE_LOCK_WAIT_SECS=60 \
        "$ROOT/bin/fm-fleet-sync.sh" alpha 2>/dev/null)
  elapsed=$(( $(date +%s) - t0 ))
  wait "$peer_pid" 2>/dev/null || true

  [ "$elapsed" -ge 2 ] || fail "the blocked sync did not wait for the peer's lock (took ${elapsed}s)"
  assert_contains "$out" "alpha: synced" "the blocked sync gave up instead of doing its work"
  assert_not_contains "$out" "alpha: skipped" "the blocked sync reported skipped rather than waiting its turn"
  pass "a sync blocked by a peer waits its turn and then advances the clone"
}

# The wait is bounded, because bin/fm-bootstrap.sh runs a sync under its own timeout
# and a wedged holder must not hang it. On expiry it reports the holder and skips,
# which is no worse than the behaviour it replaced.
test_a_wedged_holder_expires_rather_than_hanging() {
  local home clone lockpath marker peer_pid out
  home=$(make_bare_home syncwedged "$TMP_ROOT/syncwedged-projects")
  clone=$(build_sync_fixture "$home" beta)
  lockpath=$(clone_lock_path_of "$clone")
  mkdir -p "$(dirname "$lockpath")"
  marker="$TMP_ROOT/wedged-holding"

  ( flock 9 || exit 1
    touch "$marker"
    while [ -e "$marker" ]; do sleep 0.1; done ) 9>"$lockpath" >/dev/null 2>&1 &
  peer_pid=$!
  wait_for_file "$marker"

  out=$(FM_HOME="$home" FM_PROJECTS_OVERRIDE="$home/projects" \
        FM_GRAPH_REINDEX_MODE=off FM_CLONE_LOCK_WAIT_SECS=1 \
        "$ROOT/bin/fm-fleet-sync.sh" beta 2>/dev/null)
  rm -f "$marker"
  wait "$peer_pid" 2>/dev/null || true

  assert_contains "$out" "another firstmate instance has held this clone" \
    "a sync whose wait expired did not say why it skipped"
  pass "a sync whose wait expires reports the holder and skips instead of hanging"
}

# One contended clone must not consume the whole sweep. bin/fm-bootstrap.sh runs a
# full-fleet sync under a timeout of about 20s, so a clone a peer is holding could
# eat all of it and leave every other clone untouched - strictly worse than the
# skip-and-move-on the lock replaced. The budget here is deliberately shorter than
# the holder, which is that case exactly. sweep-alpha sorts first, so a sweep that
# waits before it works reaches nothing else.
test_a_contended_clone_does_not_starve_the_sweep() {
  local home lockpath marker peer_pid sync_pid outfile
  home=$(make_bare_home syncsweep "$TMP_ROOT/syncsweep-projects")
  build_sync_fixture "$home" sweep-alpha >/dev/null
  build_sync_fixture "$home" sweep-beta >/dev/null
  lockpath=$(clone_lock_path_of "$home/projects/sweep-alpha")
  mkdir -p "$(dirname "$lockpath")"
  marker="$TMP_ROOT/sweep-holding"
  outfile="$TMP_ROOT/sweep-out"

  ( flock 9 && touch "$marker" && sleep 15 ) 9>"$lockpath" >/dev/null 2>&1 &
  peer_pid=$!
  wait_for_file "$marker"

  FM_HOME="$home" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_GRAPH_REINDEX_MODE=off FM_CLONE_LOCK_WAIT_SECS=60 \
    "$ROOT/bin/fm-fleet-sync.sh" >"$outfile" 2>/dev/null &
  sync_pid=$!
  sleep 5
  kill "$sync_pid" 2>/dev/null || true
  wait "$sync_pid" 2>/dev/null || true
  rm -f "$marker"
  kill "$peer_pid" 2>/dev/null || true
  wait "$peer_pid" 2>/dev/null || true

  assert_contains "$(cat "$outfile")" "sweep-beta: synced" \
    "a clone a peer was holding starved the rest of the sweep, so nothing else synced inside the budget"
  pass "a contended clone does not starve the uncontended ones in a full-fleet sweep"
}

# make_graph_stub_root <name>: a stand-in $FM_ROOT whose graph reindex blocks until
# its marker is removed, so a case can observe whether the clone lock is still held
# while the reindex runs. Carries only the three helpers fm-fleet-sync.sh reaches
# for through $FM_ROOT.
make_graph_stub_root() {
  local dir="$TMP_ROOT/graphroot-$1"
  mkdir -p "$dir/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/fm-guard.sh"
  printf '#!/usr/bin/env bash\necho "PR off"\n' > "$dir/bin/fm-project-mode.sh"
  cat > "$dir/bin/fm-graph-reindex.sh" <<SH
#!/usr/bin/env bash
touch "$TMP_ROOT/graph-$1-running"
while [ -e "$TMP_ROOT/graph-$1-running" ]; do sleep 0.1; done
SH
  chmod +x "$dir/bin/fm-guard.sh" "$dir/bin/fm-project-mode.sh" "$dir/bin/fm-graph-reindex.sh"
  printf '%s\n' "$dir"
}

# The reindex is minutes of best-effort work that touches no git state. Held inside
# the clone's write lock it decides another instance's sync outcome, which is the
# starvation this lock exists to end rather than cause.
test_the_graph_reindex_runs_outside_the_clone_lock() {
  local home clone root lockpath rc sync_pid
  home=$(make_bare_home syncgraph "$TMP_ROOT/syncgraph-projects")
  clone=$(build_sync_fixture "$home" graphed)
  root=$(make_graph_stub_root graphed)
  lockpath=$(clone_lock_path_of "$clone")
  mkdir -p "$(dirname "$lockpath")"

  FM_HOME="$home" FM_PROJECTS_OVERRIDE="$home/projects" FM_ROOT_OVERRIDE="$root" \
    "$ROOT/bin/fm-fleet-sync.sh" graphed >/dev/null 2>&1 &
  sync_pid=$!
  wait_for_file "$TMP_ROOT/graph-graphed-running"

  rc=0
  ( flock -w 2 9 || exit 75 ) 9>"$lockpath" >/dev/null 2>&1 || rc=$?
  rm -f "$TMP_ROOT/graph-graphed-running"
  wait "$sync_pid" 2>/dev/null || true

  [ "$rc" -eq 0 ] \
    || fail "the clone stayed locked through the graph reindex, so a peer starves on work that touches no git state"
  pass "the graph reindex runs outside the clone's write lock"
}

# The lock lives on an open file descriptor, and a descriptor is inherited. A body
# that leaves anything running in the background - git's own detached `gc --auto`
# runs on this path - would otherwise hold the clone long after the runner returned,
# and one such orphan wedges every peer's sync of that clone for as long as it lives.
test_a_background_child_does_not_inherit_the_clone_lock() {
  local clone lockpath rc
  clone="$TMP_ROOT/fdleak-clone"
  mkdir -p "$clone"
  lockpath=$(clone_lock_path_of "$clone")

  ( . "$ROOT/bin/fm-peer-lib.sh"
    # shellcheck disable=SC2329  # run by name, through the lock runner
    leaves_a_child() { ( sleep 10 ) >/dev/null 2>&1 & }
    fm_clone_lock_run "$clone" leaves_a_child ) >/dev/null 2>&1

  rc=0
  ( flock -w 2 9 || exit 75 ) 9>"$lockpath" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a background child left by the locked command kept holding the clone lock"
  pass "a background child left behind by a locked command does not keep the clone locked"
}

# --- contended: the updater's refusal ---------------------------------------

# make_scratch_checkout [name]: a stand-in $FM_ROOT for the updater to act on, so no
# case here can fast-forward the real checkout it is running from. Its bin/ carries
# only what the updater's peer check reaches for by path.
make_scratch_checkout() {
  local dir="$TMP_ROOT/scratch-root-${1:-default}"
  mkdir -p "$dir/bin"
  fm_git_init_commit "$dir"
  ln -sf "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  ln -sf "$ROOT/bin/fm-peer-lib.sh" "$dir/bin/fm-peer-lib.sh"
  printf '%s\n' "$dir"
}

register_live_peer() {  # <cache> <home> <checkout> ; echoes the holder pid
  local cache=$1 home=$2 checkout=$3 sleeper
  sleep 30 >/dev/null 2>&1 &
  sleeper=$!
  printf '%s\n' "$sleeper" > "$home/state/.lock"
  FM_PEER_CACHE_DIR="$cache" bash -c \
    '. "$1/bin/fm-peer-lib.sh"; fm_peer_register "$2" "$3" "$4"' \
    _ "$ROOT" "$home" "$home/state" "$checkout"
  printf '%s\n' "$sleeper"
}

test_update_refuses_while_a_peer_is_live_and_names_it() {
  local cache peer me root out sleeper rc
  # Its own registry, so a peer another case registered cannot decide this one.
  cache="$TMP_ROOT/update-cache"
  root=$(make_scratch_checkout)
  peer=$(make_bare_home update-peer)
  me=$(make_bare_home update-me)

  # A peer mid-turn on THIS checkout: its session lock held by a live process the
  # fake ps calls claude.
  sleeper=$(register_live_peer "$cache" "$peer" "$root")

  rc=0
  out=$(PATH="$FAKEBIN:$PATH" FM_PEER_CACHE_DIR="$cache" FM_HOME="$me" \
        FM_ROOT_OVERRIDE="$root" "$ROOT/bin/fm-update.sh" 2>&1) || rc=$?
  expect_code 1 "$rc" "the updater did not refuse while a peer was live"
  assert_contains "$out" "another firstmate instance is live on this checkout" \
    "the updater refused without saying why"
  assert_contains "$out" "$peer" "the updater refused without naming which peer is holding it"
  assert_contains "$out" "fm-lock.sh status" "the updater did not say how to see the peer"

  # Control: once the peer's session ends, the same call stops refusing. Without it
  # an unconditional refusal would pass every assertion above.
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  rm -f "$peer/state/.lock"
  out=$(PATH="$FAKEBIN:$PATH" FM_PEER_CACHE_DIR="$cache" FM_HOME="$me" \
        FM_ROOT_OVERRIDE="$root" "$ROOT/bin/fm-update.sh" 2>&1 || true)
  assert_not_contains "$out" "another firstmate instance is live on this checkout" \
    "the updater still refuses after the peer's session ended"
  pass "the updater refuses while a peer shares this checkout, names it, and stops once it is gone"
}

# THE OTHER DIRECTION, and the one that turned the refusal into a refusal that never
# clears. Every secondmate home is its own full checkout, and its charter has it run
# bin/fm-session-start.sh and then idle - so it registers here and stays registered
# for as long as it is up. Matching on liveness alone made /updatefirstmate refuse
# against the one command whose own job includes fast-forwarding that secondmate.
test_update_ignores_a_live_peer_on_another_checkout() {
  local cache peer me mine theirs out sleeper entries
  cache="$TMP_ROOT/update-cache-foreign"
  mine=$(make_scratch_checkout mine)
  theirs=$(make_scratch_checkout theirs)
  peer=$(make_bare_home foreign-peer)
  me=$(make_bare_home foreign-me)

  sleeper=$(register_live_peer "$cache" "$peer" "$theirs")
  out=$(PATH="$FAKEBIN:$PATH" FM_PEER_CACHE_DIR="$cache" FM_HOME="$me" \
        FM_ROOT_OVERRIDE="$mine" "$ROOT/bin/fm-update.sh" 2>&1 || true)

  assert_not_contains "$out" "another firstmate instance is live on this checkout" \
    "a live instance running from a DIFFERENT checkout blocked this checkout's self-update"
  # Its entry is not this caller's to prune either: pruning it would make the peer
  # invisible to the instance that does share its checkout.
  entries=$(find "$cache/sessions" -type f 2>/dev/null | wc -l)
  [ "$entries" -eq 1 ] \
    || fail "the updater pruned a live peer's registry entry from another checkout ($entries left)"

  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  pass "a live instance on another checkout neither blocks this one's update nor loses its entry"
}

# --- the bare home ----------------------------------------------------------

is_foreign_verdict() {  # <home>
  ( FM_STATE_OVERRIDE="$TMP_ROOT/foreign-scratch-state"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    if fm_home_lock_is_foreign "$ROOT/bin/fm-watch.sh" "$1" ""; then
      echo foreign
    else
      echo own
    fi )
}

# fm_home_lock_is_foreign refuses the home lock when $FM_HOME is a DIFFERENT firstmate
# checkout than the watcher was launched from - the containment that stops a watcher
# started inside a crew worktree from evicting the real home's. A bare home carries no
# checkout, so it passes the early-out, which is the whole reason several instances can
# share one. Asserted in both directions: a predicate that never fires would pass the
# first half on its own.
test_a_bare_home_is_not_foreign_and_a_checkout_home_is() {
  local bare other
  bare=$(make_bare_home foreign-bare)
  other="$TMP_ROOT/foreign-checkout"
  mkdir -p "$other/bin"
  printf '#!/usr/bin/env bash\n' > "$other/bin/fm-watch.sh"

  [ "$(is_foreign_verdict "$bare")" = own ] \
    || fail "a bare home was judged foreign, so its watcher would refuse its own home lock"
  [ "$(is_foreign_verdict "$other")" = foreign ] \
    || fail "a home carrying its own checkout was NOT judged foreign, so the containment guard is not firing at all"
  pass "a bare home passes the foreign-home guard while a second checkout still trips it"
}

test_a_bare_home_verifies_and_runs() {
  local bare out rc
  bare=$(make_bare_home bare-runs)
  out=$("$ROOT/bin/fm-home-init.sh" --verify "$bare" 2>&1)
  assert_contains "$out" "verified" "a home fm-home-init.sh just created does not verify"

  # It runs: the real session lock, against the real checkout, from a home holding
  # nothing but its own state.
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$bare" "$ROOT/bin/fm-lock.sh" 2>&1)
  assert_contains "$out" "lock acquired" "a bare home could not take its own session lock"

  # And it stops verifying once it is no longer bare, rather than silently becoming a
  # home whose watcher will refuse its own lock later.
  mkdir -p "$bare/bin"
  printf '#!/usr/bin/env bash\n' > "$bare/bin/fm-watch.sh"
  rc=0
  out=$("$ROOT/bin/fm-home-init.sh" --verify "$bare" 2>&1) || rc=$?
  expect_code 1 "$rc" "verify accepted a home that had grown its own checkout"
  assert_contains "$out" "not a bare home" "verify refused without saying what is wrong"
  pass "a bare home verifies and runs, and stops verifying once it is no longer bare"
}

# env.sh is SOURCED, so its values have to survive sourcing rather than merely read
# correctly. A clones path holding $, a backtick or $(...) would otherwise be
# expanded - or run - on every session start, and verify has to read it back the same
# way the operator does or it would pass on a file that hands the session a different
# directory than it names.
test_env_sh_survives_a_path_the_shell_would_expand() {
  local projects home out got
  projects="$TMP_ROOT/cl\$ones-\$(id -u)"
  mkdir -p "$projects"
  home="$TMP_ROOT/envquote"
  "$ROOT/bin/fm-home-init.sh" "$home" --projects "$projects" >/dev/null

  # shellcheck source=/dev/null
  got=$( . "$home/env.sh" >/dev/null 2>&1; printf '%s' "${FM_PROJECTS_OVERRIDE:-}" )
  [ "$got" = "$projects" ] \
    || fail "sourcing env.sh gave a different clones directory than the home was created with: '$got' not '$projects'"

  out=$("$ROOT/bin/fm-home-init.sh" --verify "$home" 2>&1) \
    || fail "verify refused a home whose clones path holds shell metacharacters: $out"
  pass "env.sh survives a clones path the shell would otherwise expand"
}

# --- private: the per-task temp root ----------------------------------------

# make_teardown_root <id> <tasktmp>: a stand-in checkout the real fm-teardown.sh
# resolves into, with the libraries it sources symlinked and the helpers it calls
# stubbed. A nonexistent worktree makes both `[ -d "$WT" ]` guards skip, so teardown
# runs straight to the temp-root cleanup this case is about. Mirrors
# tests/fm-gotmp.test.sh's fixture.
make_teardown_root() {
  local tid=$1 tasktmp=$2 fake="$TMP_ROOT/teardown-$1" lib
  mkdir -p "$fake/bin/backends" "$fake/state"
  ln -s "$ROOT/bin/fm-teardown.sh" "$fake/bin/fm-teardown.sh"
  for lib in fm-backend.sh fm-tmux-lib.sh fm-lock-lib.sh fm-taskstate-lib.sh fm-peer-lib.sh; do
    ln -s "$ROOT/bin/$lib" "$fake/bin/$lib"
  done
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  printf 'fm_tasks_axi_compatible() { return 1; }\n' > "$fake/bin/fm-tasks-axi-lib.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/bin/fm-guard.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/bin/fm-fleet-sync.sh"
  chmod +x "$fake/bin/fm-guard.sh" "$fake/bin/fm-fleet-sync.sh"
  cat > "$fake/state/$tid.meta" <<META
window=fakeses:fm-$tid
worktree=$TMP_ROOT/nonexistent-worktree-$tid
project=$TMP_ROOT/nonexistent-project-$tid
harness=claude
kind=ship
mode=PR
yolo=off
tasktmp=$tasktmp
META
  printf '%s\n' "$fake"
}

# Task ids are short kebab slugs, so two instances both running "fix-login" is
# ordinary. They used to share ONE 0700 directory holding a forwarded credential
# file, and either teardown deleted it. Teardown removes the recorded tasktmp= AND
# recomputes the root from $FM_HOME as a backstop, so both paths run here.
test_two_homes_do_not_share_one_task_temp_root() {
  local task_id=sharedtmp-x1 a b root_a root_b fake
  a=$(make_bare_home tmp-a)
  b=$(make_bare_home tmp-b)
  root_a=$( . "$ROOT/bin/fm-peer-lib.sh"; fm_task_tmp_root "$a" "$task_id" )
  root_b=$( . "$ROOT/bin/fm-peer-lib.sh"; fm_task_tmp_root "$b" "$task_id" )
  [ "$root_a" != "$root_b" ] \
    || fail "two homes running the same task id got one temp root: $root_a"

  mkdir -p "$root_a" "$root_b"
  printf 'a\n' > "$root_a/crew-env.sh"
  printf 'b\n' > "$root_b/crew-env.sh"

  fake=$(make_teardown_root "$task_id" "$root_a")
  FM_HOME="$a" FM_ROOT_OVERRIDE="$fake" FM_STATE_OVERRIDE="$fake/state" \
    "$fake/bin/fm-teardown.sh" "$task_id" >/dev/null 2>&1 || true

  assert_absent "$root_a" "teardown did not remove its own task's temp root"
  assert_present "$root_b/crew-env.sh" \
    "one instance's teardown deleted another instance's task temp root, credential file and all"
  pass "two homes running one task id keep separate temp roots, and teardown removes only its own"
}

test_two_homes_take_independent_session_locks
test_wake_queues_do_not_leak_between_homes
test_two_clones_of_one_upstream_derive_one_warm_lock_key
test_second_warmer_yields_to_the_first
test_one_clone_reached_two_ways_takes_one_lock
test_a_blocked_sync_waits_and_then_syncs
test_a_wedged_holder_expires_rather_than_hanging
test_a_contended_clone_does_not_starve_the_sweep
test_the_graph_reindex_runs_outside_the_clone_lock
test_a_background_child_does_not_inherit_the_clone_lock
test_update_refuses_while_a_peer_is_live_and_names_it
test_update_ignores_a_live_peer_on_another_checkout
test_a_bare_home_is_not_foreign_and_a_checkout_home_is
test_a_bare_home_verifies_and_runs
test_env_sh_survives_a_path_the_shell_would_expand
test_two_homes_do_not_share_one_task_temp_root
