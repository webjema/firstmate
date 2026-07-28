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
#   (h) a FAILED install        -> exits 0 and names the cold root
#   (i) not inside a pool       -> a clean no-op
#   (j) --harvest               -> caches an existing tree and installs NOTHING
#   (k) --probe                 -> reports clone support
#   (l) a spent shared budget   -> every root is skipped, and the skip is reported
#   (m) ONE budget for ALL roots: a root that eats it leaves none for the rest
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
assert_contains "$out" "does not support cp -c" "(e) the missing clone support is REPORTED, not silent"
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

# --- (h) a failed install is reported, never fatal ---------------------------

SLOT=$(new_case failed)
fake_npm "$TMP_ROOT/failed" 1
out=$(run_provision "$SLOT"); rc=$?
expect_code 0 "$rc" "(h) a failed provision never fails the warm that called it"
assert_contains "$out" "install FAILED" "(h) the failure is named"
assert_contains "$out" "finished with at least one cold root" "(h) and summarized"
pass "(h) a failed install exits 0 and reports the cold root"

# --- (i) a worktree outside any pool -----------------------------------------

LOOSE="$TMP_ROOT/loose"
mkdir -p "$LOOSE"
printf '{"name":"x"}\n' > "$LOOSE/package.json"
out=$(FM_TREEHOUSE_ROOT="$TMP_ROOT/nowhere" "$PROVISION" "$LOOSE" 2>&1); rc=$?
expect_code 0 "$rc" "(i) a non-pool path is not an error"
pass "(i) a worktree outside a pool is a clean no-op"

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
  'clone: unsupported') expect_code 1 "$rc" "(k) unsupported probes exit 1" ;;
  *) fail "(k) --probe said something else: $out" ;;
esac
pass "(k) --probe reports this volume's clone support"

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
