#!/usr/bin/env bash
# Tests for the post-commit backup hook that bin/fm-hooks-install.sh emits.
#
# The hook mirrors every commit to refs/heads/wip/<host>/<branch> on origin, so
# that work which is committed but not yet pushed survives losing the machine.
# Its load-bearing property is NOT that the backup arrives - it is that trying to
# make one can never cost the commit anything, because post-commit runs after the
# commit is already made. Every "broken" case below therefore asserts the commit
# still succeeds, silently, and only then asserts what did or did not reach the
# remote.
#
# Matrix:
#   (a) a commit on a feature branch lands a wip ref on the remote
#   (b) the default branch never produces one - wip/main is noise
#   (c) detached HEAD is a silent no-op
#   (d) no remote configured is a silent no-op
#   (e) an unreachable remote is a silent no-op
#   (f) a remote that REJECTS the push still leaves the commit landed
#   (g) a slow remote does not slow the commit
#   (h) a slow remote does not wedge a caller reading $(git commit ...)
#   (i) an amended commit still backs up - the ref is a mirror, so it is forced
#   (j) prune drops merged wip refs, keeps unmerged ones, and never touches
#       another host's
#   (k) a foreign post-commit hook is never clobbered; re-running is idempotent
#   (l) the emitted hook is shellcheck-clean under the repo's pinned config
#   (m) commits made faster than a push completes still leave the NEWEST commit
#       backed up, rather than whichever concurrent push happened to finish last
#   (n) a project hook that CHAINS into ours is not mistaken for ours
#   (o) a core.hooksPath inside the working tree is skipped, not planted in
#   (p) a prune stamp from the future does not switch pruning off
#   (q) a default branch that origin/HEAD does not name is learned and then left
#       alone
#
# (g) and (h) are the two that would have made this hook a tax on every commit in
# the fleet. (h) is the specific trap: a backgrounded subshell inherits its
# caller's stdout, so an unredirected background push keeps the pipe open and a
# caller reading the commit's output blocks on it long after git has exited.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOKS="$ROOT/bin/fm-hooks-install.sh"
TMP_ROOT=$(fm_test_tmproot fm-wip-push-hook-tests)
fm_git_identity

# The same host slug the hook computes, so assertions name the real ref.
HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)
HOST=${HOST//[^A-Za-z0-9._-]/-}
[ -n "$HOST" ] || HOST=unknown

# Prune stays off unless a test asks for it, so no test's sweep perturbs another.
export FM_WIP_PRUNE_INTERVAL=86400

# make_repo <name>: a bare origin with one commit on main, plus a clone of it
# with the hook installed. Echoes the clone's path; the bare is "<clone>.git".
# A real clone (not `remote add`) is deliberate: it is what sets
# refs/remotes/origin/HEAD, which is how the hook learns the default branch.
make_repo() {
  local name=$1 seed bare work
  seed="$TMP_ROOT/$name.seed"
  bare="$TMP_ROOT/$name.git"
  work="$TMP_ROOT/$name"

  git init -q -b main "$seed"
  printf 'seed\n' > "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" commit -qm initial
  git clone --quiet --bare "$seed" "$bare"
  git clone --quiet "file://$bare" "$work"
  git -C "$work" config user.name "$GIT_AUTHOR_NAME"
  git -C "$work" config user.email "$GIT_AUTHOR_EMAIL"

  "$HOOKS" "$work" >/dev/null 2>&1
  printf '%s\n' "$work"
}

# commit_on <work> <branch> <message>: switch to <branch> (creating it) and make
# one commit. Prints nothing; returns git commit's own exit status, which is the
# thing most of these tests are actually asserting on.
commit_on() {
  local work=$1 branch=$2 msg=$3
  git -C "$work" checkout -q -B "$branch" 2>/dev/null
  printf '%s\n' "$msg" >> "$work/work.txt"
  git -C "$work" add work.txt
  git -C "$work" commit -qm "$msg"
}

# The push is asynchronous by design, so every positive assertion polls rather
# than sleeping a guessed interval.
wait_for_ref() {
  local bare=$1 ref=$2 limit=${3:-30} waited=0
  while [ "$waited" -lt "$limit" ]; do
    git -C "$bare" rev-parse --quiet --verify "$ref" >/dev/null 2>&1 && return 0
    sleep 1
    waited=$(( waited + 1 ))
  done
  return 1
}

# A negative needs a settle window instead: give the background job time to have
# done the wrong thing, then assert it did not.
settle() { sleep 3; }

wip_refs() {
  git -C "$1" for-each-ref --format='%(refname)' 'refs/heads/wip/**' 2>/dev/null
}

# reject_pushes <bare> / slow_pushes <bare> <secs>: server-side hooks on the bare
# repo. file:// transport runs git-receive-pack locally, so these really do fire.
reject_pushes() {
  mkdir -p "$1/hooks"
  printf '#!/bin/sh\necho "rejected by test" >&2\nexit 1\n' > "$1/hooks/pre-receive"
  chmod +x "$1/hooks/pre-receive"
}

slow_pushes() {
  mkdir -p "$1/hooks"
  printf '#!/bin/sh\nsleep %s\nexit 0\n' "$2" > "$1/hooks/pre-receive"
  chmod +x "$1/hooks/pre-receive"
}

# slow_first_push <bare> <secs>: only the FIRST push served is slow. That is what
# turns an ordering bug from flaky into deterministic - it guarantees the push
# carrying the OLDEST commit is the one that finishes last.
slow_first_push() {
  mkdir -p "$1/hooks"
  cat > "$1/hooks/pre-receive" <<EOF
#!/bin/sh
if [ ! -e "$1/served-one" ]; then
  : > "$1/served-one"
  sleep $2
fi
exit 0
EOF
  chmod +x "$1/hooks/pre-receive"
}

# (a) The feature itself. ----------------------------------------------------
test_feature_branch_commit_reaches_the_remote() {
  local work bare code=0
  work=$(make_repo happy)
  bare="$work.git"

  commit_on "$work" feature/login "add login" || code=$?
  expect_code 0 "$code" "happy: the commit itself must succeed"

  wait_for_ref "$bare" "refs/heads/wip/$HOST/feature/login" \
    || fail "happy: no refs/heads/wip/$HOST/feature/login on the remote after 30s"

  local remote_sha local_sha
  remote_sha=$(git -C "$bare" rev-parse "refs/heads/wip/$HOST/feature/login")
  local_sha=$(git -C "$work" rev-parse HEAD)
  [ "$remote_sha" = "$local_sha" ] \
    || fail "happy: the backup ref is at $remote_sha, not at HEAD ($local_sha)"
  pass "a commit on a feature branch mirrors to refs/heads/wip/<host>/<branch> on origin"
}

# (b) wip/main would be noise: main is on the remote already. ----------------
test_default_branch_never_backs_up() {
  local work bare code=0 refs
  work=$(make_repo defaultbranch)
  bare="$work.git"

  commit_on "$work" main "on main" || code=$?
  expect_code 0 "$code" "default: the commit itself must succeed"
  settle

  refs=$(wip_refs "$bare")
  [ -z "$refs" ] \
    || fail "default: main produced backup refs it should not have: $refs"
  pass "no backup ref is pushed from the default branch"
}

# (c)-(f) The four ways this is asked to fail, all of which must be silent. ---
test_detached_head_is_a_silent_noop() {
  local work bare out code=0 refs
  work=$(make_repo detached)
  bare="$work.git"

  git -C "$work" checkout -q --detach
  printf 'detached\n' >> "$work/work.txt"
  git -C "$work" add work.txt
  out=$(git -C "$work" commit -m "detached work" 2>&1) || code=$?

  expect_code 0 "$code" "detached: a commit on a detached HEAD must still succeed"
  assert_not_contains "$out" 'wip/' "detached: the hook must say nothing"
  settle
  refs=$(wip_refs "$bare")
  [ -z "$refs" ] || fail "detached: pushed a backup with no branch name: $refs"
  pass "a detached HEAD is a silent no-op - there is no branch to name a backup after"
}

test_no_remote_is_a_silent_noop() {
  local work out code=0
  work=$(make_repo noremote)
  git -C "$work" checkout -q -b feature/x
  git -C "$work" remote remove origin

  printf 'no remote\n' >> "$work/work.txt"
  git -C "$work" add work.txt
  out=$(git -C "$work" commit -m "no remote" 2>&1) || code=$?

  expect_code 0 "$code" "noremote: a commit with no origin must still succeed"
  assert_not_contains "$out" 'fatal' "noremote: git's own error must not surface"
  pass "a repository with no origin commits normally and silently"
}

test_unreachable_remote_is_a_silent_noop() {
  local work out code=0 started elapsed
  work=$(make_repo offline)
  git -C "$work" checkout -q -b feature/x
  git -C "$work" remote set-url origin "file://$TMP_ROOT/definitely-not-here.git"

  started=$SECONDS
  printf 'offline\n' >> "$work/work.txt"
  git -C "$work" add work.txt
  out=$(git -C "$work" commit -m "offline" 2>&1) || code=$?
  elapsed=$(( SECONDS - started ))

  expect_code 0 "$code" "offline: a commit against an unreachable remote must still succeed"
  assert_not_contains "$out" 'fatal' "offline: the failed push must not surface"
  [ "$elapsed" -lt 10 ] \
    || fail "offline: the commit took ${elapsed}s - it is waiting on the doomed push"
  pass "an unreachable remote costs the commit neither its exit status nor its speed"
}

# The brief's break-it-deliberately case: the push is refused outright. -------
test_rejected_push_still_leaves_the_commit_landed() {
  local work bare out code=0 refs
  work=$(make_repo rejected)
  bare="$work.git"
  reject_pushes "$bare"

  git -C "$work" checkout -q -b feature/x
  printf 'rejected\n' >> "$work/work.txt"
  git -C "$work" add work.txt
  out=$(git -C "$work" commit -m "rejected push" 2>&1) || code=$?

  expect_code 0 "$code" "rejected: a refused backup must not fail the commit"
  assert_not_contains "$out" 'rejected by test' "rejected: the remote's refusal must not surface"
  settle

  git -C "$work" rev-parse --quiet --verify HEAD >/dev/null \
    || fail "rejected: the commit did not land"
  refs=$(wip_refs "$bare")
  [ -z "$refs" ] || fail "rejected: a refused push somehow created $refs"
  pass "a remote that refuses the backup still leaves the commit landed, silently"
}

# (g) The tax this hook must not levy. ---------------------------------------
test_a_slow_remote_does_not_slow_the_commit() {
  local work bare code=0 started elapsed
  work=$(make_repo slow)
  bare="$work.git"
  slow_pushes "$bare" 20

  git -C "$work" checkout -q -b feature/x
  printf 'slow\n' >> "$work/work.txt"
  git -C "$work" add work.txt

  started=$SECONDS
  git -C "$work" commit -qm "slow remote" || code=$?
  elapsed=$(( SECONDS - started ))

  expect_code 0 "$code" "slow: the commit must succeed"
  [ "$elapsed" -lt 10 ] \
    || fail "slow: the commit took ${elapsed}s against a 20s remote - the push is not backgrounded"
  pass "a 20s remote does not slow the commit - the backup runs in the background"
}

# (h) The specific trap: a background subshell inherits its caller's stdout, so
# an unredirected push holds the pipe and $(git commit ...) blocks on it long
# after git itself has exited. This is the only test that would catch that. ---
test_a_slow_remote_does_not_wedge_a_caller_reading_the_output() {
  local work bare out code=0 started elapsed
  work=$(make_repo pipe)
  bare="$work.git"
  slow_pushes "$bare" 20

  git -C "$work" checkout -q -b feature/x
  printf 'pipe\n' >> "$work/work.txt"
  git -C "$work" add work.txt

  started=$SECONDS
  out=$(git -C "$work" commit -m "captured output" 2>&1) || code=$?
  elapsed=$(( SECONDS - started ))

  expect_code 0 "$code" "pipe: the commit must succeed"
  [ "$elapsed" -lt 10 ] \
    || fail "pipe: reading the commit's output took ${elapsed}s against a 20s remote - the background push is holding the pipe open"
  assert_contains "$out" 'captured output' "pipe: the commit's own output must still be readable"
  pass "a caller reading \$(git commit ...) is not wedged by the background push holding its pipe"
}

# (i) The ref is a mirror of HEAD, not a history, so it is forced. Without that
# the first amend makes every later backup non-fast-forward and the hook fails
# silently from then on - a worse outcome than superseding one backup. --------
test_amended_commit_still_backs_up() {
  local work bare first second code=0
  work=$(make_repo amended)
  bare="$work.git"

  commit_on "$work" feature/x "first" || code=$?
  expect_code 0 "$code" "amend: the first commit must succeed"
  wait_for_ref "$bare" "refs/heads/wip/$HOST/feature/x" \
    || fail "amend: the first backup never arrived"
  first=$(git -C "$bare" rev-parse "refs/heads/wip/$HOST/feature/x")

  git -C "$work" commit -q --amend -m "first, amended"
  local waited=0
  while [ "$waited" -lt 30 ]; do
    second=$(git -C "$bare" rev-parse "refs/heads/wip/$HOST/feature/x" 2>/dev/null || true)
    [ -n "$second" ] && [ "$second" != "$first" ] && break
    sleep 1
    waited=$(( waited + 1 ))
  done

  [ "$second" != "$first" ] \
    || fail "amend: the backup is still at the pre-amend commit - the push is not forced"
  [ "$second" = "$(git -C "$work" rev-parse HEAD)" ] \
    || fail "amend: the backup does not match the amended HEAD"
  pass "an amended commit re-mirrors - the backup tracks HEAD instead of going stale"
}

# (m) Commits made faster than a push completes. -----------------------------
test_rapid_commits_leave_the_newest_commit_backed_up() {
  local work bare head got code=0
  work=$(make_repo rapid)
  bare="$work.git"
  slow_first_push "$bare" 6

  local msg
  for msg in one two three; do
    commit_on "$work" feature/rapid "$msg" || code=$?
    expect_code 0 "$code" "rapid: commit '$msg' must succeed"
  done
  head=$(git -C "$work" rev-parse HEAD)

  # Long enough for the deliberately slow first push to finish, so a straggler
  # carrying an older commit has already had its chance to overwrite the ref.
  sleep 12

  got=$(git -C "$bare" rev-parse --quiet --verify "refs/heads/wip/$HOST/feature/rapid" 2>/dev/null || true)
  [ "$got" = "$head" ] \
    || fail "rapid: the backup settled at ${got:-nothing}, not the newest commit $head - concurrent pushes landed out of order"
  pass "three commits inside one push's latency still leave the NEWEST commit backed up"
}

# (j) The life story of the wip/ namespace. ----------------------------------
test_prune_drops_merged_refs_only() {
  local work bare merged_sha code=0 refs
  work=$(make_repo prune)
  bare="$work.git"

  # A commit that IS on main: its backup is redundant the moment main carries it.
  git -C "$work" checkout -q -B main
  printf 'landed\n' >> "$work/work.txt"
  git -C "$work" add work.txt
  git -C "$work" commit -qm "landed on main"
  git -C "$work" push --quiet origin main
  merged_sha=$(git -C "$work" rev-parse HEAD)
  git -C "$work" fetch --quiet origin

  # Three refs the sweep must tell apart.
  git -C "$bare" update-ref "refs/heads/wip/$HOST/landed" "$merged_sha"
  git -C "$bare" update-ref "refs/heads/wip/someotherhost/landed" "$merged_sha"

  git -C "$work" checkout -q -b feature/unlanded
  printf 'unlanded\n' >> "$work/work.txt"
  git -C "$work" add work.txt
  git -C "$work" commit -qm "never merged"
  git -C "$work" push --quiet --force origin "HEAD:refs/heads/wip/$HOST/unlanded"

  # Now let the next commit's sweep run, instead of waiting a day for it.
  rm -f "$work/.git/fm-wip-prune.stamp"
  export FM_WIP_PRUNE_INTERVAL=0
  commit_on "$work" feature/unlanded "trigger the sweep" || code=$?
  export FM_WIP_PRUNE_INTERVAL=86400
  expect_code 0 "$code" "prune: the triggering commit must succeed"

  local waited=0
  while [ "$waited" -lt 30 ]; do
    git -C "$bare" rev-parse --quiet --verify "refs/heads/wip/$HOST/landed" >/dev/null 2>&1 || break
    sleep 1
    waited=$(( waited + 1 ))
  done

  refs=$(wip_refs "$bare")
  assert_not_contains "$refs" "refs/heads/wip/$HOST/landed" \
    "prune: a backup whose work is already on the default branch must be dropped"
  assert_contains "$refs" "refs/heads/wip/$HOST/unlanded" \
    "prune: an UNMERGED backup must be kept - it is the only copy of exactly the work this hook exists to protect"
  assert_contains "$refs" "refs/heads/wip/someotherhost/landed" \
    "prune: another host's backup is not ours to delete"
  pass "prune drops landed backups, keeps unlanded ones, and leaves other hosts alone"
}

# The sweep costs a round trip to list every remote head, so it must not be paid
# per commit. A fresh clone has no stamp and so sweeps on its first commit, which
# is the cheap and correct thing to do; what this asserts is that the SECOND
# commit inside the interval does not sweep again. ---------------------------
test_prune_waits_for_its_interval() {
  local work bare code=0 merged_sha refs waited=0
  work=$(make_repo prune_interval)
  bare="$work.git"

  git -C "$work" checkout -q -B main
  printf 'landed\n' >> "$work/work.txt"
  git -C "$work" add work.txt
  git -C "$work" commit -qm "landed on main"
  git -C "$work" push --quiet origin main
  merged_sha=$(git -C "$work" rev-parse HEAD)
  git -C "$work" fetch --quiet origin

  # Spend the first, free sweep, and wait for the stamp that records it.
  commit_on "$work" feature/y "first commit" || code=$?
  expect_code 0 "$code" "interval: the first commit must succeed"
  while [ "$waited" -lt 30 ] && [ ! -f "$work/.git/fm-wip-prune.stamp" ]; do
    sleep 1
    waited=$(( waited + 1 ))
  done
  assert_present "$work/.git/fm-wip-prune.stamp" \
    "interval: the first commit should have swept and stamped"

  # A merged backup planted AFTER that sweep must survive the next commit.
  git -C "$bare" update-ref "refs/heads/wip/$HOST/landed" "$merged_sha"
  commit_on "$work" feature/y "second commit inside the interval" || code=$?
  expect_code 0 "$code" "interval: the second commit must succeed"
  settle

  refs=$(wip_refs "$bare")
  assert_contains "$refs" "refs/heads/wip/$HOST/landed" \
    "interval: a second commit swept again - the sweep must be amortized, not per-commit"
  pass "the sweep is amortized to once a day rather than paid on every commit"
}

# (k) The same never-clobber contract the rest of the bundle keeps. -----------
test_never_clobbers_a_foreign_post_commit() {
  local work out before after
  work=$(make_repo foreign)
  rm -f "$work/.git/hooks/post-commit"
  printf '#!/bin/sh\n# hand written\nexit 0\n' > "$work/.git/hooks/post-commit"
  chmod +x "$work/.git/hooks/post-commit"
  before=$(cat "$work/.git/hooks/post-commit")

  out=$("$HOOKS" "$work" 2>&1)
  after=$(cat "$work/.git/hooks/post-commit")

  [ "$before" = "$after" ] || fail "foreign: a hand-written post-commit hook was overwritten"
  assert_contains "$out" 'left untouched' "foreign: says it left the existing hook alone"
  pass "a project's own post-commit hook is reported, never clobbered"
}

test_install_is_idempotent() {
  local work first second out
  work=$(make_repo idempotent)
  first=$(cat "$work/.git/hooks/post-commit")
  out=$("$HOOKS" "$work" 2>&1)
  second=$(cat "$work/.git/hooks/post-commit")

  [ "$first" = "$second" ] || fail "idempotent: a re-run changed the installed hook"
  assert_contains "$out" 'wip-push' "idempotent: a re-run still reports on the hook"
  pass "re-running the installer leaves the hook byte-identical"
}

test_check_never_writes() {
  local work out
  work="$TMP_ROOT/checkonly"
  git init -q -b main "$work"
  out=$("$HOOKS" --check "$work" 2>&1)

  assert_absent "$work/.git/hooks/post-commit" "check: --check must never install"
  assert_absent "$work/.git/hooks/fm-wip-push" "check: --check must not write the hook body either"
  assert_contains "$out" 'HOOKS_MISSING' "check: reports the hook is absent"
  pass "--check reports the missing backup hook without writing one"
}

# (n) The trap the never-clobber check itself sets. --------------------------
#
# The message in (k) tells a project to call fm-wip-push from its own hook. Any
# wrapper that takes that advice NAMES fm-wip-push, so a check for that string
# would read the wrapper as ours and delete it - on the next task, silently,
# because crews run the installer every time.
test_never_clobbers_a_hook_that_chains_into_ours() {
  local work out before after
  work=$(make_repo chained)
  cat > "$work/.git/hooks/post-commit" <<'CHAIN'
#!/bin/sh
./scripts/notify-ci.sh
exec "$(dirname "$0")/fm-wip-push"
CHAIN
  chmod +x "$work/.git/hooks/post-commit"
  before=$(cat "$work/.git/hooks/post-commit")

  out=$("$HOOKS" "$work" 2>&1)
  after=$(cat "$work/.git/hooks/post-commit")

  [ "$before" = "$after" ] \
    || fail "chained: a project hook that calls fm-wip-push was overwritten by the installer"
  assert_contains "$out" 'left untouched' "chained: says it left the existing hook alone"
  assert_present "$work/.git/hooks/fm-wip-push" \
    "chained: the body must still be installed, or the advice to call it is a lie"
  pass "a project hook that chains into ours is not mistaken for ours"
}

# (o) core.hooksPath inside the working tree - husky sets exactly this. --------
test_hooks_path_inside_the_working_tree_is_skipped() {
  local work out
  work=$(make_repo huskylike)
  rm -f "$work/.git/hooks/post-commit" "$work/.git/hooks/fm-wip-push"
  mkdir -p "$work/.husky"
  git -C "$work" config core.hooksPath .husky

  out=$("$HOOKS" "$work" 2>&1)

  assert_absent "$work/.husky/post-commit" \
    "husky: an untracked hook in the working tree is dirt teardown refuses on"
  assert_contains "$out" 'skipped' "husky: says why it installed nothing"
  pass "a hooks path inside the working tree is reported and skipped, never planted in"
}

# (p) One bad clock must not disable pruning for as long as it is wrong. -------
test_a_future_prune_stamp_does_not_disable_pruning() {
  local work bare merged_sha code=0 waited=0
  work=$(make_repo futurestamp)
  bare="$work.git"

  merged_sha=$(git -C "$bare" rev-parse refs/heads/main)
  git -C "$bare" update-ref "refs/heads/wip/$HOST/landed" "$merged_sha"
  git -C "$work" fetch -q origin

  # Ten years ahead: a resumed snapshot, a bad container clock, one NTP step.
  printf '%s\n' "$(( $(date +%s) + 315360000 ))" > "$work/.git/fm-wip-prune.stamp"

  commit_on "$work" feature/clock "after the clock jumped" || code=$?
  expect_code 0 "$code" "clock: the commit itself must succeed"

  while [ "$waited" -lt 30 ]; do
    git -C "$bare" rev-parse --quiet --verify "refs/heads/wip/$HOST/landed" >/dev/null 2>&1 || break
    sleep 1
    waited=$(( waited + 1 ))
  done

  assert_not_contains "$(wip_refs "$bare")" "refs/heads/wip/$HOST/landed" \
    "clock: a stamp in the future left pruning switched off"
  pass "a prune stamp from the future is ignored rather than obeyed until time catches up"
}

# (q) A default branch that origin/HEAD does not name. -------------------------
#
# `git remote add` never sets origin/HEAD, and a project whose default branch is
# not main/master/trunk would then collect a backup ref for it that the prune
# could never delete either - it needs the same name for its ancestry base.
test_default_branch_is_learned_when_origin_head_is_unset() {
  local seed bare work first second code=0
  seed="$TMP_ROOT/develop.seed"
  bare="$TMP_ROOT/develop.git"
  work="$TMP_ROOT/develop"

  git init -q -b develop "$seed"
  printf 'seed\n' > "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" commit -qm initial
  git clone --quiet --bare "$seed" "$bare"

  git init -q -b develop "$work"
  git -C "$work" config user.name "$GIT_AUTHOR_NAME"
  git -C "$work" config user.email "$GIT_AUTHOR_EMAIL"
  git -C "$work" remote add origin "file://$bare"
  git -C "$work" fetch -q origin
  git -C "$work" reset -q --hard origin/develop
  [ -z "$(git -C "$work" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)" ] \
    || fail "develop: the fixture is wrong - remote add is not supposed to set origin/HEAD"
  "$HOOKS" "$work" >/dev/null 2>&1

  # First commit: nothing knows the default yet, so one backup ref is expected.
  commit_on "$work" develop "first" || code=$?
  expect_code 0 "$code" "develop: the first commit must succeed"
  wait_for_ref "$work/.git" "refs/remotes/origin/wip/$HOST/develop" 5 >/dev/null 2>&1 || true
  local cache_waited=0
  while [ "$cache_waited" -lt 30 ]; do
    [ -s "$work/.git/fm-wip-default" ] && break
    sleep 1
    cache_waited=$(( cache_waited + 1 ))
  done
  [ "$(cat "$work/.git/fm-wip-default" 2>/dev/null || true)" = develop ] \
    || fail "develop: the default branch was never resolved and cached"
  first=$(git -C "$bare" rev-parse --quiet --verify "refs/heads/wip/$HOST/develop" 2>/dev/null || true)

  # Second commit: the cache now answers, so the default branch must go quiet.
  commit_on "$work" develop "second" || code=$?
  expect_code 0 "$code" "develop: the second commit must succeed"
  settle
  second=$(git -C "$bare" rev-parse --quiet --verify "refs/heads/wip/$HOST/develop" 2>/dev/null || true)

  [ "$second" = "$first" ] \
    || fail "develop: the default branch is still being backed up after its name was learned"
  pass "a default branch origin/HEAD does not name is learned once, then left alone"
}

# (l) The emitted hook is production shell and is held to the repo's own bar. --
test_emitted_hook_is_shellcheck_clean() {
  local work out code=0
  work=$(make_repo lintable)
  out=$("$ROOT/bin/fm-lint.sh" "$work/.git/hooks/fm-wip-push" "$work/.git/hooks/post-commit" 2>&1) || code=$?
  if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -qi 'shellcheck.*\(not found\|version\)'; then
    pass "SKIPPED: the pinned shellcheck is unavailable, so the emitted hook was not linted"
    return 0
  fi
  expect_code 0 "$code" "lint: the emitted hooks must be shellcheck-clean: $out"
  pass "both emitted hook files pass the repo's own pinned shellcheck"
}

test_feature_branch_commit_reaches_the_remote
test_default_branch_never_backs_up
test_detached_head_is_a_silent_noop
test_no_remote_is_a_silent_noop
test_unreachable_remote_is_a_silent_noop
test_rejected_push_still_leaves_the_commit_landed
test_a_slow_remote_does_not_slow_the_commit
test_a_slow_remote_does_not_wedge_a_caller_reading_the_output
test_amended_commit_still_backs_up
test_rapid_commits_leave_the_newest_commit_backed_up
test_prune_drops_merged_refs_only
test_prune_waits_for_its_interval
test_never_clobbers_a_foreign_post_commit
test_never_clobbers_a_hook_that_chains_into_ours
test_hooks_path_inside_the_working_tree_is_skipped
test_a_future_prune_stamp_does_not_disable_pruning
test_default_branch_is_learned_when_origin_head_is_unset
test_install_is_idempotent
test_check_never_writes
test_emitted_hook_is_shellcheck_clean
