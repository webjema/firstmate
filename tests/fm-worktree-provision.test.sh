#!/usr/bin/env bash
# Tests for bin/fm-worktree-provision.sh - APFS-clone provisioning of a pooled
# worktree's dependency trees.
#
# The contract (its header owns it): discover the install roots, CLONE each one's
# node_modules from a per-pool cache, reconcile with the project's own installer,
# and seed the cache from the result. Nothing under projects/ is ever touched;
# the cache seeds itself from the first correct tree it sees.
#
# npm is stubbed (the suite's usual fakebin/PATH shim) - a real reconcile would
# install multiple GB. The stub records every invocation and its cwd, so these
# tests assert WHICH roots were installed, not merely that something ran. The
# cloning itself is exercised for real: `cp -c` on the test tmpdir, which is on
# the same APFS volume the pool would be.
#
#   (a) discovery: the repo root and lockfile dirs are roots; a bare package.json
#       below the root is NOT (optiroq's packages/* must stay out)
#   (b) an empty cache          -> installs, then seeds the cache
#   (c) a seeded cache          -> clones from it, then reconciles
#   (d) a STALE cache           -> still clones (reconcile fixes it), and re-seeds
#   (e) no clone support        -> installs with no clone, and never falls back to
#                                  a real `cp -R` (that would double the disk)
#   (f) a pnpm root             -> reconciled, never cloned (pnpm already hardlinks)
#   (g) a held cache lock       -> the second provisioner does nothing
#   (h) a FAILED install        -> exits 1 and names the cold root
#   (i) not inside a pool       -> REFUSED: nothing installed, nothing cached
#   (j) --harvest               -> caches an existing tree and installs NOTHING
#   (k) --probe                 -> reports clone support
#   (l) a spent shared budget   -> every root is skipped, and the skip is reported
#   (m) ONE budget for ALL roots: a root that eats it leaves none for the rest
#   (n) an installer that rewrites its lockfile -> the cache is not re-harvested
#   (o) a non-APFS volume       -> refused even though `cp -c` itself exits 0
#   (p) a FAILED cache refresh  -> the previous cache entry survives intact
#   (q) an installer that rewrites a TRACKED file -> the slot comes back CLEAN,
#       and a modification that was already there is left alone
#   (r) a rewrite `git diff` cannot see (CRLF under eol normalization) -> still
#       restored, because that is the one that bricked slots in practice
#   (s) the same guarantee on the NO-CLONE path, which is what Linux and WSL run
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROVISION="$ROOT/bin/fm-worktree-provision.sh"
REAL_PATH=$PATH   # never mutated: each case's stubs are scoped to that case
# fm_test_tmproot registers its cleanup trap inside the command-substitution
# subshell, so the root it just made is gone when that subshell exits; recreate
# it here, as the other suites do. Then resolve it: on macOS the temp root sits
# under a symlinked /var and the script reports resolved paths, so unresolved
# fixture paths would never match its output.
TMP_ROOT=$(fm_test_tmproot fm-worktree-provision)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# --- a sandbox: a treehouse root, a pool, a slot, a scripted npm ---------------
#
# A slot lives at <treehouse-root>/<pool>/<n>/<repo>, which is the layout the
# script derives its pool key from, so the fixture must reproduce it exactly.

NPM_LOG=""
FAKEBIN=""

# new_case <name> [layout]: build a fresh pool + slot and echo the slot path.
# layout "npm" (default) gives a root package.json plus two lockfile subdirs and
# one bare-package.json subdir; "pnpm" gives a single pnpm root.
new_case() {  # <name> [layout]
  local name=$1 layout=${2:-npm} case_dir slot
  case_dir="$TMP_ROOT/$name"
  slot="$case_dir/th/pool-$name/1/repo"
  mkdir -p "$slot"
  if [ "$layout" = pnpm ]; then
    printf '{"name":"r"}\n' > "$slot/package.json"
    printf 'lockfileVersion: 6\n' > "$slot/pnpm-lock.yaml"
  else
    printf '{"name":"r"}\n' > "$slot/package.json"
    mkdir -p "$slot/src/app" "$slot/src/ui" "$slot/packages/lib"
    printf '{"name":"app"}\n' > "$slot/src/app/package.json"
    printf '{}\n' > "$slot/src/app/package-lock.json"
    printf '{"name":"ui"}\n' > "$slot/src/ui/package.json"
    printf '{}\n' > "$slot/src/ui/package-lock.json"
    # A package.json with NO lockfile, below the root: not an install root.
    printf '{"name":"lib"}\n' > "$slot/packages/lib/package.json"
  fi
  printf '%s\n' "$slot"
}

# fake_npm <case-dir> [exit-code]: an npm/pnpm/yarn stub that records its cwd and
# creates the node_modules a real install would, so the script's later steps see
# a populated tree. It sets FAKEBIN/NPM_LOG for the case rather than touching the
# suite's own PATH, so case (e)'s deliberately broken `cp` cannot leak into the
# cases that follow it.
fake_npm() {  # <case-dir> [exit-code]
  local case_dir=$1 rc=${2:-0} fakebin log tool
  fakebin=$(fm_fakebin "$case_dir")
  log="$case_dir/npm.log"
  : > "$log"
  for tool in npm pnpm yarn; do
    cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s cwd=%s\n' "\$(basename "\$0")" "\$*" "\$PWD" >> "$log"
[ "$rc" -eq 0 ] || exit $rc
mkdir -p node_modules/pkg
printf 'installed\n' > node_modules/pkg/index.js
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
  FAKEBIN=$fakebin
  NPM_LOG=$log
}

# run_provision <slot> [args...]: run the script with the sandbox's treehouse
# root and the current case's stubs, capturing stdout+stderr.
run_provision() {  # <slot> [args...]
  local slot=$1 th
  shift
  th=$(cd "$slot/../../.." && pwd -P)
  PATH="$FAKEBIN:$REAL_PATH" FM_TREEHOUSE_ROOT="$th" "$PROVISION" "$slot" "$@" 2>&1
}

cache_dir_of() {  # <slot>
  local slot=$1 th pool
  th=$(cd "$slot/../../.." && pwd -P)
  pool=$(basename "$(cd "$slot/../.." && pwd -P)")
  printf '%s/.fm-dep-cache/%s' "$th" "$pool"
}

# clone_supported: does this test volume actually clone? The degrade path (e) is
# asserted regardless, but the clone-for-real cases only mean something here.
clone_supported() {
  FM_TREEHOUSE_ROOT="$TMP_ROOT" "$PROVISION" --probe "$TMP_ROOT" >/dev/null 2>&1
}

# --- (a) discovery ------------------------------------------------------------

SLOT=$(new_case discovery)
fake_npm "$TMP_ROOT/discovery"
out=$(run_provision "$SLOT")
assert_contains "$out" "  .:" "(a) the repo root is an install root"
assert_contains "$out" "  src/app:" "(a) a lockfile dir is an install root"
assert_contains "$out" "  src/ui:" "(a) the second lockfile dir is an install root"
assert_not_contains "$out" "packages/lib" "(a) a bare package.json below the root is NOT an install root"
assert_grep "cwd=$SLOT" "$NPM_LOG" "(a) the root was installed"
assert_grep "cwd=$SLOT/src/app" "$NPM_LOG" "(a) src/app was installed"
pass "(a) install roots are discovered, and a bare package.json below the root is not one"

# --- (b) an empty cache seeds itself -----------------------------------------

SLOT=$(new_case seed)
fake_npm "$TMP_ROOT/seed"
out=$(run_provision "$SLOT")
assert_contains "$out" "clone=no" "(b) nothing to clone from on the first run"
if clone_supported; then
  assert_contains "$out" "cache seeded" "(b) the first correct tree seeds the cache"
  CACHE=$(cache_dir_of "$SLOT")
  [ -f "$CACHE/./node_modules/pkg/index.js" ] || fail "(b) the root tree was not cached"
  [ -f "$CACHE/src/app/node_modules/pkg/index.js" ] || fail "(b) src/app was not cached"
fi
pass "(b) an empty cache installs cold and seeds itself from the result"

# --- (c) a seeded cache is cloned from ---------------------------------------

if clone_supported; then
  SLOT=$(new_case reuse)
  fake_npm "$TMP_ROOT/reuse"
  run_provision "$SLOT" >/dev/null            # seed
  rm -rf "$SLOT/node_modules" "$SLOT/src/app/node_modules" "$SLOT/src/ui/node_modules"
  : > "$NPM_LOG"
  out=$(run_provision "$SLOT")
  assert_contains "$out" "clone=yes" "(c) the second slot clones from the cache"
  assert_not_contains "$out" "clone from the cache failed" "(c) the clone succeeded"
  assert_grep "cwd=$SLOT" "$NPM_LOG" "(c) a clone is still reconciled - never handed over unverified"
  pass "(c) a seeded cache is cloned from, and the clone is still reconciled"
else
  pass "(c) skipped: this volume does not support cp -c clones"
fi

# --- (d) a stale cache is still cloned from, and re-seeded --------------------

if clone_supported; then
  SLOT=$(new_case stale)
  fake_npm "$TMP_ROOT/stale"
  run_provision "$SLOT" >/dev/null            # seed
  rm -rf "$SLOT/node_modules" "$SLOT/src/app/node_modules" "$SLOT/src/ui/node_modules"
  printf '{"name":"r","dependencies":{"new":"1"}}\n' > "$SLOT/package.json"   # deps moved on
  : > "$NPM_LOG"
  out=$(run_provision "$SLOT")
  assert_contains "$out" "clone=yes" "(d) a stale cache is STILL the right thing to start from"
  assert_contains "$out" "cache seeded" "(d) the stale entry is refreshed from the reconciled tree"
  pass "(d) a stale cache is cloned from anyway, then re-seeded"
else
  pass "(d) skipped: this volume does not support cp -c clones"
fi

# --- (e) no clone support degrades to a plain install ------------------------

SLOT=$(new_case degrade)
CASE=$TMP_ROOT/degrade
fake_npm "$CASE"
# A cp with no working -c: exactly what a non-APFS volume or GNU cp looks like.
cat > "$CASE/fakebin/cp" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = "-c" ] && exit 1
done
exec /bin/cp "$@"
SH
chmod +x "$CASE/fakebin/cp"
out=$(run_provision "$SLOT")
# Platform-neutral: on macOS the reason is "this cp has no working -c", on a Linux
# runner it is "not APFS" - what must hold on both is that the degrade is announced.
assert_contains "$out" "installing without cloning" "(e) the missing clone support is REPORTED, not silent"
assert_grep "cwd=$SLOT" "$NPM_LOG" "(e) the install still ran"
assert_absent "$(cache_dir_of "$SLOT")" "(e) nothing is cached without clone support - a real copy would double the disk"
pass "(e) no clone support installs plainly, says so, and never falls back to a real copy"

# --- (f) pnpm is left alone ---------------------------------------------------

SLOT=$(new_case pnpm pnpm)
fake_npm "$TMP_ROOT/pnpm"
out=$(run_provision "$SLOT")
assert_contains "$out" "pnpm store (no clone needed)" "(f) a pnpm root is reconciled, not cloned"
assert_grep "pnpm install" "$NPM_LOG" "(f) pnpm's own installer ran"
assert_absent "$(cache_dir_of "$SLOT")" "(f) pnpm needs no cache - its store already hardlinks"
pass "(f) a pnpm root is reconciled only, and never cached"

# --- (g) one provisioner per pool cache --------------------------------------

SLOT=$(new_case lock)
fake_npm "$TMP_ROOT/lock"
TH=$(cd "$SLOT/../../.." && pwd -P)
POOL=$(basename "$(cd "$SLOT/../.." && pwd -P)")
mkdir -p "$TH/.fm-warm-locks"
# Hold the cache lock the way the directory fallback records a LIVE owner.
LOCK="$TH/.fm-warm-locks/dep-cache-$POOL"
mkdir -p "$LOCK"
printf '%s\n' "$$" > "$LOCK/pid"
# shellcheck source=bin/fm-pool-lib.sh disable=SC1091
. "$ROOT/bin/fm-pool-lib.sh"
fm_pool_boot_id > "$LOCK/boot"
out=$(FM_POOL_LOCK_FORCE_DIR=1 run_provision "$SLOT")
assert_contains "$out" "another provisioner holds this pool's cache" "(g) the second provisioner stands down"
assert_no_grep "cwd=$SLOT" "$NPM_LOG" "(g) and installs nothing"
rm -rf "$LOCK"
pass "(g) a held cache lock makes the second provisioner a no-op"

# --- (h) a failed install is reported, and the status is NOT swallowed --------
# Exiting 0 on a failed install is what let bin/fm-pool-warm.sh log a slot whose
# every install failed as "free and warm". Never failing the WARM is that caller's
# job, not this script's - it reports, the caller decides.

SLOT=$(new_case failed)
fake_npm "$TMP_ROOT/failed" 1
out=$(run_provision "$SLOT"); rc=$?
expect_code 1 "$rc" "(h) a cold root is reported in the exit status, not swallowed"
assert_contains "$out" "install FAILED" "(h) the failure is named"
assert_contains "$out" "finished with at least one cold root" "(h) and summarized"
pass "(h) a failed install exits 1 and reports the cold root"

# --- (i) a worktree outside any pool is REFUSED -------------------------------
# This is AGENTS.md rail 1 in code: firstmate must never run an installer inside
# projects/<repo>. An earlier guard derived the pool key with `cd "$wt/../.."`,
# which succeeds for very nearly any path, so it never fired - and a test that
# asserted only rc == 0 passed vacuously against a guard that did nothing. What
# must be asserted is that NOTHING HAPPENED to the directory.

LOOSE_CASE="$TMP_ROOT/loose"
LOOSE="$LOOSE_CASE/tree"
mkdir -p "$LOOSE"
printf '{"name":"x"}\n' > "$LOOSE/package.json"
printf '{}\n' > "$LOOSE/package-lock.json"
fake_npm "$LOOSE_CASE"
run_outside() {  # <path> <treehouse-root>
  PATH="$FAKEBIN:$REAL_PATH" FM_TREEHOUSE_ROOT="$2" "$PROVISION" "$1" 2>&1
}

out=$(run_outside "$LOOSE" "$TMP_ROOT/nowhere"); rc=$?
expect_code 1 "$rc" "(i) a path outside the treehouse root is a refusal, not a success"
assert_contains "$out" "refusing" "(i) the refusal is stated"
assert_no_grep "cwd=" "$NPM_LOG" "(i) NO installer ran outside a pool"
[ ! -e "$LOOSE/node_modules" ] || fail "(i) something was installed into a non-pool directory"
assert_absent "$TMP_ROOT/nowhere/.fm-dep-cache" "(i) and no cache was written"

# Inside the treehouse root, but not a <pool>/<slot>/<repo> slot: the shape must be
# checked too, or anything a user happens to keep under ~/.treehouse qualifies.
MISSHAPEN="$TMP_ROOT/loose/th/pool-x/notanumber/repo"
mkdir -p "$MISSHAPEN"
printf '{"name":"x"}\n' > "$MISSHAPEN/package.json"
printf '{}\n' > "$MISSHAPEN/package-lock.json"
: > "$NPM_LOG"
out=$(run_outside "$MISSHAPEN" "$TMP_ROOT/loose/th"); rc=$?
expect_code 1 "$rc" "(i) a non-numeric slot is not a treehouse slot"
assert_no_grep "cwd=" "$NPM_LOG" "(i) and nothing was installed there either"
pass "(i) a worktree outside a pool is refused, with nothing installed and nothing cached"

# --- (j) --harvest caches without installing ---------------------------------

if clone_supported; then
  SLOT=$(new_case harvest)
  fake_npm "$TMP_ROOT/harvest"
  mkdir -p "$SLOT/node_modules/pkg"
  printf 'x\n' > "$SLOT/node_modules/pkg/index.js"
  : > "$NPM_LOG"
  out=$(run_provision "$SLOT" --harvest)
  assert_contains "$out" "harvested into the cache" "(j) an existing tree is harvested"
  [ -f "$(cache_dir_of "$SLOT")/./node_modules/pkg/index.js" ] || fail "(j) the tree was not cached"
  assert_no_grep "cwd=" "$NPM_LOG" "(j) a harvest installs nothing"
  pass "(j) --harvest caches an existing tree and installs nothing"
else
  pass "(j) skipped: this volume does not support cp -c clones"
fi

# --- (k) --probe --------------------------------------------------------------

out=$(FM_TREEHOUSE_ROOT="$TMP_ROOT" "$PROVISION" --probe "$TMP_ROOT" 2>&1); rc=$?
case "$out" in
  'clone: supported') expect_code 0 "$rc" "(k) supported probes exit 0" ;;
  # An unsupported probe must carry the REASON, not just the verdict: an operator
  # told only "no" cannot tell a wrong volume from a wrong tool.
  'clone: unsupported - '?*) expect_code 1 "$rc" "(k) unsupported probes exit 1" ;;
  *) fail "(k) --probe said something else: $out" ;;
esac
pass "(k) --probe reports this volume's clone support, with a reason when it says no"

# --- (l) a spent budget starts nothing ----------------------------------------
# The provisioner runs inside a warm that already holds a treehouse lease and the
# pool lock. Starting an install with no time left to finish in would hold both
# past the bound its caller was given, for a root that gets abandoned anyway.

SLOT=$(new_case spent)
fake_npm "$TMP_ROOT/spent"
out=$(FM_PROVISION_DEADLINE=$(( $(date +%s) - 1 )) run_provision "$SLOT")
assert_contains "$out" "the warm's time budget is spent" "(l) the skip is reported, not silent"
assert_no_grep "cwd=" "$NPM_LOG" "(l) and nothing is installed with the budget already gone"
pass "(l) a spent shared budget skips every root and says so"

# --- (m) one budget for ALL roots, not one budget EACH ------------------------
# A three-root project must not be able to hold its caller's lease for three times
# the bound. The first root here eats the whole budget, so the rest get none.

SLOT=$(new_case shared)
CASE=$TMP_ROOT/shared
fake_npm "$CASE"
cat > "$CASE/fakebin/npm" <<SH
#!/usr/bin/env bash
printf 'npm %s cwd=%s\n' "\$*" "\$PWD" >> "$NPM_LOG"
sleep 60
SH
chmod +x "$CASE/fakebin/npm"
out=$(FM_PROVISION_DEADLINE=$(( $(date +%s) + 3 )) run_provision "$SLOT")
assert_contains "$out" "the warm's time budget is spent" "(m) the later roots are skipped, not given a fresh budget each"
[ "$(grep -c 'cwd=' "$NPM_LOG")" -eq 1 ] \
  || fail "(m) $(grep -c 'cwd=' "$NPM_LOG") installs started on one budget - the budget is not shared"
pass "(m) the time budget is shared across every root of one warm"

# --- (n) an installer that rewrites its own lockfile must not thrash the cache -
# npm does exactly this. If the cache recorded the fingerprint of the POST-install
# tree, no later slot - which presents the lockfile git has - would ever match it,
# and every warm would re-harvest a multi-GB tree for nothing.

if clone_supported; then
  SLOT=$(new_case rewrite)
  CASE=$TMP_ROOT/rewrite
  fake_npm "$CASE"
  cat > "$CASE/fakebin/npm" <<SH
#!/usr/bin/env bash
printf 'npm %s cwd=%s\n' "\$*" "\$PWD" >> "$CASE/npm.log"
[ -f package-lock.json ] && printf '{"rewritten":true}\n' > package-lock.json
mkdir -p node_modules/pkg && printf 'x\n' > node_modules/pkg/index.js
exit 0
SH
  chmod +x "$CASE/fakebin/npm"
  out=$(run_provision "$SLOT")
  assert_contains "$out" "cache seeded" "(n) the first run seeds the cache"
  # Model the next slot: a fresh checkout, so the lockfile is the one git has.
  rm -rf "$SLOT/node_modules" "$SLOT/src/app/node_modules" "$SLOT/src/ui/node_modules"
  printf '{}\n' > "$SLOT/src/app/package-lock.json"
  printf '{}\n' > "$SLOT/src/ui/package-lock.json"
  out=$(run_provision "$SLOT")
  assert_contains "$out" "clone=yes" "(n) the second slot still clones from the cache"
  assert_not_contains "$out" "cache seeded" "(n) and must NOT re-harvest a cache that is still right"
  pass "(n) a lockfile the installer rewrote does not invalidate the cache"
else
  pass "(n) skipped: this volume does not support cp -c clones"
fi

# --- (o) a volume that is not APFS is refused, whatever `cp -c` says ----------
# macOS `cp -c` falls back to copyfile(2) and EXITS 0 when it cannot clone, so a
# one-byte probe reports "supported" on HFS+, exFAT, an external drive and a network
# mount alike - and every later copy is a full-byte copy logged as a clone. The
# operator reads 96 MB per slot while paying 2.7 GB. Here `cp` is the REAL one and
# succeeds; only the reported filesystem says no. The refusal must come from that.

SLOT=$(new_case notapfs)
CASE=$TMP_ROOT/notapfs
fake_npm "$CASE"
cat > "$CASE/fakebin/df" <<'SH'
#!/usr/bin/env bash
echo "Filesystem 512-blocks Used Available Capacity Mounted on"
echo "/dev/fake9s1 100 50 50 50% /fake"
SH
cat > "$CASE/fakebin/mount" <<'SH'
#!/usr/bin/env bash
echo "/dev/fake9s1 on /fake (hfs, local, journaled)"
SH
chmod +x "$CASE/fakebin/df" "$CASE/fakebin/mount"
out=$(run_provision "$SLOT")
assert_contains "$out" "not APFS" "(o) the refusal names the filesystem, not a generic no"
assert_contains "$out" "installing without cloning" "(o) and it degrades rather than lying about a clone"
assert_not_contains "$out" "clone=yes" "(o) nothing may be reported as cloned on a non-cloning volume"
assert_grep "cwd=$SLOT" "$NPM_LOG" "(o) the install still ran"
assert_absent "$(cache_dir_of "$SLOT")" "(o) and nothing was cached - a real copy would double the disk"
pass "(o) a non-APFS volume is refused even though cp -c exits 0 on it"

# --- (p) a failed cache refresh must not destroy the cache it was refreshing --
# The cache entry is the thing every other slot clones FROM. Emptying it before the
# new copy lands means a refresh interrupted by the warm's timeout, a full disk, or
# a kill leaves the pool with nothing to clone from at all - strictly worse than the
# stale entry it was replacing.

if clone_supported; then
  SLOT=$(new_case refresh)
  CASE=$TMP_ROOT/refresh
  fake_npm "$CASE"
  run_provision "$SLOT" >/dev/null                       # seed the cache for real
  CACHE=$(cache_dir_of "$SLOT")
  [ -f "$CACHE/./node_modules/pkg/index.js" ] || fail "(p) fixture: the cache was not seeded"
  printf 'canary\n' > "$CACHE/./node_modules/pkg/canary.js"
  # Now make every RECURSIVE copy fail, leaving can_clone's one-byte probe working:
  # the script still believes cloning is possible, and the refresh fails mid-flight.
  cat > "$CASE/fakebin/cp" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = "-R" ] && exit 1
done
exec /bin/cp "$@"
SH
  chmod +x "$CASE/fakebin/cp"
  rm -rf "$SLOT/node_modules" "$SLOT/src/app/node_modules" "$SLOT/src/ui/node_modules"
  printf '{"name":"r","dependencies":{"new":"2"}}\n' > "$SLOT/package.json"   # force a refresh
  out=$(run_provision "$SLOT")
  assert_contains "$out" "cache seed FAILED" "(p) the failed refresh is reported"
  [ -f "$CACHE/./node_modules/pkg/canary.js" ] \
    || fail "(p) a failed cache refresh destroyed the still-usable cache entry"
  pass "(p) a failed cache refresh leaves the previous entry intact"
else
  pass "(p) skipped: this volume does not support cp -c clones"
fi

# --- (q) the slot must come back CLEAN ---------------------------------------
# treehouse resets a returned slot with `git clean -fd` - no -x, and no checkout -
# so it cannot revert a TRACKED file, and npm rewrites the lockfile it installed
# from. A slot left `dirty` is skipped by every later `treehouse get` and refused by
# `prune`: each warm would retire one slot permanently. The restore is surgical, not
# a blanket checkout: work that was already modified in the slot must survive it.

SLOT=$(new_case clean)
CASE=$TMP_ROOT/clean
printf 'node_modules/\n' > "$SLOT/.gitignore"
git -C "$SLOT" init -q
git -C "$SLOT" add -A
git -C "$SLOT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fixture
cat > "$TMP_ROOT/clean-npm" <<'SH'
#!/usr/bin/env bash
[ -f package-lock.json ] && printf '{"rewritten":true}\n' > package-lock.json
mkdir -p node_modules/pkg && printf 'x\n' > node_modules/pkg/index.js
exit 0
SH
fake_npm "$CASE"
cp "$TMP_ROOT/clean-npm" "$CASE/fakebin/npm"
chmod +x "$CASE/fakebin/npm"
# A tracked edit that was ALREADY there before the warm: a crew's own work.
printf '{"name":"r","mine":true}\n' > "$SLOT/package.json"
out=$(run_provision "$SLOT")
assert_contains "$out" "restored" "(q) the restore is reported, not silent"
# `git status`, not `git diff`, because that is the predicate treehouse itself
# uses to call a slot dirty - and case (r) below is where the two disagree.
DIRTY=$(git -C "$SLOT" status --porcelain --untracked-files=no | sed 's/^...//')
case "$DIRTY" in
  package.json) ;;
  *) fail "(q) the returned slot's tracked state is '$DIRTY', expected only the pre-existing package.json edit" ;;
esac
assert_contains "$(cat "$SLOT/package.json")" '"mine":true' \
  "(q) a blanket checkout would have discarded the edit that was already there"
pass "(q) an installer that rewrites a tracked file leaves the slot clean, sparing prior edits"

# --- (r) a rewrite `git diff` refuses to see --------------------------------
# The case that actually bricked slots on the operator's box (optiroq, verified
# 2026-07-30): the repo normalizes line endings, npm rewrote package-lock.json
# with CRLF, and `git diff --name-only HEAD` reported NOTHING because it compares
# normalized content - while `git status` reported ` M` and treehouse retired the
# slot. A restore keyed on diff therefore found nothing to restore and left the
# slot bricked, which is why tracked_modified asks status instead.

SLOT=$(new_case eol)
CASE=$TMP_ROOT/eol
printf 'node_modules/\n' > "$SLOT/.gitignore"
printf '* text=auto eol=lf\n' > "$SLOT/.gitattributes"
printf '{\n  "lockfileVersion": 3\n}\n' > "$SLOT/src/app/package-lock.json"
git -C "$SLOT" init -q
git -C "$SLOT" add -A
git -C "$SLOT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fixture
cat > "$TMP_ROOT/eol-npm" <<'SH'
#!/usr/bin/env bash
# The whole rewrite is the line endings: same bytes otherwise, so the normalized
# content still matches HEAD and only `git status` can see the difference.
if [ -f package-lock.json ]; then
  awk '{ printf "%s\r\n", $0 }' package-lock.json > .lock.crlf && mv .lock.crlf package-lock.json
fi
mkdir -p node_modules/pkg && printf 'x\n' > node_modules/pkg/index.js
exit 0
SH
fake_npm "$CASE"
cp "$TMP_ROOT/eol-npm" "$CASE/fakebin/npm"
chmod +x "$CASE/fakebin/npm"
# Guard the fixture before relying on it: this test defends nothing unless git
# really does hide a CRLF-only rewrite from diff while status still reports it.
( cd "$SLOT/src/app" && "$CASE/fakebin/npm" >/dev/null 2>&1 ) || true
[ -z "$(git -C "$SLOT" diff --name-only HEAD -- 2>/dev/null)" ] \
  || fail "(r) fixture: git diff CAN see the CRLF rewrite, so this case no longer reproduces the trap"
[ -n "$(git -C "$SLOT" status --porcelain --untracked-files=no)" ] \
  || fail "(r) fixture: git status cannot see the CRLF rewrite either, so there is nothing to restore"
git -C "$SLOT" checkout HEAD -- . 2>/dev/null
rm -rf "$SLOT/src/app/node_modules"
out=$(run_provision "$SLOT")
assert_contains "$out" "restored" "(r) a CRLF-only rewrite is seen and restored"
DIRTY=$(git -C "$SLOT" status --porcelain --untracked-files=no)
[ -z "$DIRTY" ] || fail "(r) the slot came back dirty ('$DIRTY') - treehouse would retire it"
pass "(r) a rewrite only \`git status\` can see still leaves the slot clean"

# --- (s) the clean-slot guarantee is not macOS-only ---------------------------
# The clone is the macOS-specific half; the INSTALL is universal. On Linux (and
# WSL) can_clone fails cleanly - GNU cp has no -c - and the provision degrades to
# a plain install, which still runs the project's own installer INSIDE the leased
# slot and still rewrites the tracked lockfile. So the slot is bricked there too,
# and the restore has to cover the degraded path, not just the cloning one.

SLOT=$(new_case cleandegrade)
CASE=$TMP_ROOT/cleandegrade
printf 'node_modules/\n' > "$SLOT/.gitignore"
git -C "$SLOT" init -q
git -C "$SLOT" add -A
git -C "$SLOT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fixture
fake_npm "$CASE"
cat > "$CASE/fakebin/npm" <<'SH'
#!/usr/bin/env bash
[ -f package-lock.json ] && printf '{"rewritten":true}\n' > package-lock.json
mkdir -p node_modules/pkg && printf 'x\n' > node_modules/pkg/index.js
exit 0
SH
chmod +x "$CASE/fakebin/npm"
# A cp with no working -c: what every GNU-cp platform looks like to can_clone.
cat > "$CASE/fakebin/cp" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = "-c" ] && exit 1
done
exec /bin/cp "$@"
SH
chmod +x "$CASE/fakebin/cp"
out=$(run_provision "$SLOT")
assert_contains "$out" "installing without cloning" "(s) the fixture must exercise the DEGRADED path, or it proves nothing about Linux"
DIRTY=$(git -C "$SLOT" status --porcelain --untracked-files=no)
[ -z "$DIRTY" ] \
  || fail "(s) the slot came back dirty ($DIRTY) on the no-clone path - a Linux/WSL warm would brick it"
pass "(s) the slot comes back clean on the no-clone path too, so the fix is not macOS-only"
