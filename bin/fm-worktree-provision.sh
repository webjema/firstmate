#!/usr/bin/env bash
# fm-worktree-provision.sh - populate a pooled worktree's dependency trees by
# APFS CLONE from a per-pool cache, then reconcile with the project's own
# installer. THIS HEADER IS THE SINGLE OWNER OF THE PROVISIONING CONTRACT.
#
# Usage: fm-worktree-provision.sh <worktree-path>   provision it (clone + reconcile)
#        fm-worktree-provision.sh <worktree-path> --harvest
#                                                  only refresh the cache FROM it
#        fm-worktree-provision.sh --probe <src> [<dst>]
#                                                  print whether a clone from <src>
#                                                  to <dst> (default <src>) is
#                                                  possible, and exit 0/1
#
# WHY. Every pooled worktree used to grow its own full, independent node_modules,
# because nothing installed dependencies on creation and each crew installed from
# scratch inside its own slot. Measured on this box before this script existed:
# ~/.treehouse held 6.5 GB across four optiroq slots (2.4 + 2.4 + 1.6 GB, plus a
# 25 MB slot that was created and never built in). Every one of those installs
# was a full copy of very nearly the same tree.
#
# THE TECHNIQUE IS `cp -c`: an APFS copy-on-write CLONE. Unchanged files share
# their blocks with the source, so a second slot costs only what actually differs,
# and the copy is near-instant because no data is moved. `npm install` afterwards
# reconciles whatever the clone got wrong - a changed lockfile, a missing
# platform binary - so the result is a CORRECT tree, not merely a populated one.
# Cloning without that reconcile would be the real hazard, and is never done.
#
# DISCOVERY, NOT A HARDCODED LAYOUT. firstmate is multi-project: optiroq installs
# in three places (repo root, src/portal-ui, src/admin-app) and the next project
# will differ. An install root is discovered as: the repo root when it has a
# package.json, plus any directory holding a lockfile within FM_PROVISION_MAX_DEPTH.
# A package.json with no lockfile below the root is NOT an install root - that is
# what keeps optiroq's packages/* and layers/sharp, which are never installed
# separately, out of it. See discover_roots.
#
# THE CACHE is one directory per pool at
# $TREEHOUSE_ROOT/.fm-dep-cache/<pool>/<subpath>/node_modules, a sibling of the
# .fm-warm-locks directory firstmate already keeps there. It sits beside the pool
# deliberately: `cp -c` clones only WITHIN one APFS volume, and this placement
# makes same-volume structural rather than something to hope for.
#
# ONLY A POOLED WORKTREE IS EVER PROVISIONED, and that guard is structural rather
# than advisory: the path must resolve INSIDE $TREEHOUSE_ROOT and match the
# <pool>/<slot>/<repo> shape treehouse lays a slot out in, with a numeric slot.
# See pool_key_of. An earlier version derived the pool key from `cd "$wt/../.."`,
# which succeeds for very nearly any path - so the guard never fired and the
# script would happily run `npm install` in projects/<repo>, the read-only clone
# AGENTS.md rail 1 forbids writing to. A guard that cannot fail is not a guard.
#
# A PROVISIONED SLOT MUST COME BACK CLEAN. npm rewrites the lockfile it installed
# from, and that lockfile is a TRACKED file. treehouse's reset is `git clean -fd` -
# no -x, no checkout - so it removes untracked cruft but CANNOT revert a tracked
# edit: the returned slot is `dirty`, and treehouse then skips it on every later
# `get` and refuses to prune it. Every warm would retire another slot permanently.
# So the provision records which tracked paths were already modified before it
# started, and restores from HEAD exactly those the installer added - never a
# blanket checkout, which would discard work that was already there. See
# restore_tracked, and note that it runs on the kill path too: a warm killed
# mid-install must not brick the slot either.
#
# THE CACHE SEEDS ITSELF, and that is why nothing under projects/ is ever
# written. The first worktree that ends up with a correct node_modules - a crew
# that installed for itself, or a reconcile here - is HARVESTED into the cache,
# and every later slot clones from it. So there is no canonical source to
# nominate, no primary clone to seed, and no widening of firstmate's read-only
# posture toward projects/. A pool with nothing to harvest yet simply reports
# no-source and installs cold, exactly as it did before this script.
#
# A HARVEST NEVER READS A SLOT SOMEONE ELSE IS USING. It reads only the worktree
# it was handed, and its callers hand it one they hold exclusively: fm-pool-warm.sh
# holds the treehouse lease across the whole warm. Cloning out of an arbitrary
# sibling slot would race a crew mid-install and cache a half-written tree.
#
# STALENESS is a fingerprint of each root's package.json and lockfile. When it
# changes the cache entry is refreshed from the freshly reconciled worktree, so
# the cache tracks the project instead of rotting into a permanently wrong tree.
# It gates only that REFRESH, never the clone: a stale cached tree is still the
# right thing to start from, because the reconcile turns a nearly-right tree into
# a correct one far more cheaply than it builds one from nothing. Gating the
# clone on it instead made every dependency change pay a full cold install, and
# an installer that rewrites its own lockfile (npm does) never matched at all.
#
# DEGRADING IS DETECTED, NEVER ASSUMED - AND `cp -c` EXITING 0 IS NOT DETECTION.
# On macOS `cp -c` falls back to copyfile(2) and exits 0 when it cannot clone, so
# a one-byte probe reports "supported" on HFS+, exFAT, an external drive and a
# network mount alike, and every later copy is a real full-byte copy logged as a
# clone. The operator would read 96 MB per slot while paying 2.7 GB. So can_clone
# asks the three questions that actually decide it, of the src/dst PAIR:
#   1. do both paths sit on the SAME volume? (`cp -c` never clones across one)
#   2. is that volume APFS? (the only filesystem here that clones at all)
#   3. does this cp implement -c at all? (GNU cp does not, so Linux fails cleanly
#      right here, which is the property that keeps this honest on CI)
# Any question it cannot answer means NO CLONE - the plain install runs and the
# reason is printed. It never falls back to a `cp -R`, which would copy every byte
# for real and double the very disk this script exists to save, and it never
# claims a clone it has not established.
#
# pnpm IS ALREADY BETTER THAN THIS and is left alone: it hardlinks from a global
# store, so its node_modules is near-zero on disk already and cloning it would add
# nothing. pnpm roots reconcile only.
#
# ONE SHARED TIME BUDGET. FM_PROVISION_DEADLINE (an epoch second) bounds the
# WHOLE provision rather than each install separately, and bin/fm-pool-warm.sh
# sets it to its own deadline. Without it a three-root project would hold that
# caller's treehouse lease and pool lock for three times the bound it was given -
# and a leaked lease removes a slot from the pool permanently. A root reached with
# no budget left is reported as skipped, never started.
#
# THIS IS CALLED FROM THE WARM PATH, NOT FROM A treehouse HOOK, and that is not an
# oversight: treehouse ignores hooks in a repo's own treehouse.toml BY DESIGN, and
# its only working hook home is the user's GLOBAL config. docs/treehouse-backend.md
# records the evidence. Read it before proposing a repo-level hook again.
#
# THE EXIT STATUS IS THE ANSWER: 0 every root is installed, 1 at least one root is
# COLD (or the path was refused), 2 a usage error. Its caller is what must never
# fail: bin/fm-pool-warm.sh exits 0 either way, releases the lease either way, and
# merely logs a cold slot differently from a warm one. Swallowing the status here
# instead is how a warm whose every install failed still reported "free and warm".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREEHOUSE_ROOT="${FM_TREEHOUSE_ROOT:-$HOME/.treehouse}"

# shellcheck source=bin/fm-pool-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pool-lib.sh"

# How deep below the worktree root a lockfile is looked for. Deep enough for the
# src/<app> and packages/<pkg> layouts projects actually use, shallow enough that
# the scan stays cheap on a big tree.
FM_PROVISION_MAX_DEPTH=${FM_PROVISION_MAX_DEPTH:-3}

say() { printf '%s\n' "$*"; }

# --- clone support ----------------------------------------------------------

# device_of <path>: the device backing <path>, as df names it. df -P is POSIX and
# its second line's first field is the device on both platforms.
device_of() {  # <path>
  df -P "$1" 2>/dev/null | awk 'NR==2 { print $1 }'
}

# fs_type_of <device>: that device's filesystem type, lowercased by the OS already,
# or empty when it cannot be read - which callers must treat as "no clone".
# macOS: "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, ...)"
# Linux: "/dev/sda1 on / type ext4 (rw,relatime)"
# The macOS form is the one that decides anything here (nothing else clones), but
# both are read so the answer is never a silent empty on a GNU box.
fs_type_of() {  # <device>
  mount 2>/dev/null | awk -v d="$1" '
    $1 == d {
      for (i = 2; i <= NF; i++) {
        if ($i == "type" && i < NF) { print $(i + 1); exit }
        if ($i ~ /^\(/) { t = substr($i, 2); sub(/[,)]$/, "", t); print t; exit }
      }
    }'
}

# can_clone <src-dir> <dst-dir>: will a `cp -c` from src to dst be a REAL
# copy-on-write clone? The header owns why exiting 0 is not evidence of one. On a
# no, CLONE_WHY carries the reason, because a silent degrade is what let this
# overstate the saving by 28x in the first place.
CLONE_WHY=""
can_clone() {  # <src-dir> <dst-dir>
  local src=$1 dst=$2 sdev ddev fs probe rc=0
  CLONE_WHY=""

  sdev=$(device_of "$src")
  ddev=$(device_of "$dst")
  if [ -z "$sdev" ] || [ -z "$ddev" ]; then
    CLONE_WHY="the volume behind $src or $dst could not be read"
    return 1
  fi
  if [ "$sdev" != "$ddev" ]; then
    CLONE_WHY="$src ($sdev) and $dst ($ddev) are on different volumes, and cp -c never clones across one"
    return 1
  fi

  fs=$(fs_type_of "$sdev")
  if [ "$fs" != apfs ]; then
    CLONE_WHY="$sdev is ${fs:-of an unreadable type}, not APFS - cp -c would silently copy every byte instead of cloning"
    return 1
  fi

  # Last, and only now that a clone is possible at all: does this cp implement -c?
  # GNU cp does not, which is where a Linux box fails, cleanly and with a reason.
  probe=$(mktemp -d "$dst/.fm-clone-probe.XXXXXX" 2>/dev/null) || {
    CLONE_WHY="no probe could be written into $dst"
    return 1
  }
  printf 'x' > "$probe/src" 2>/dev/null || rc=1
  [ "$rc" -eq 0 ] && { cp -c "$probe/src" "$probe/dst" 2>/dev/null || rc=1; }
  rm -rf "$probe" 2>/dev/null || true
  [ "$rc" -eq 0 ] || CLONE_WHY="this cp has no working -c (GNU cp has no such flag)"
  return $rc
}

# clone_tree <src-dir> <dst-dir>: CoW-clone a whole directory, atomically from the
# destination's point of view. It clones into a temp sibling and only then swaps,
# because <dst> is sometimes the CACHE ENTRY a later slot will clone FROM: the
# earlier `rm -rf "$dst"` first meant a refresh interrupted by the warm's timeout,
# a full disk, or a kill destroyed a still-usable cache and left the pool with
# nothing to clone from. The temp lives beside the destination so the swap is a
# rename on the same volume, never a copy.
clone_tree() {  # <src-dir> <dst-dir>
  local src=$1 dst=$2 parent tmp
  [ -d "$src" ] || return 1
  parent=$(dirname "$dst")
  mkdir -p "$parent" 2>/dev/null || return 1
  tmp=$(mktemp -d "$parent/.fm-clone.XXXXXX" 2>/dev/null) || return 1
  if ! cp -c -R "$src" "$tmp/new" 2>/dev/null; then
    rm -rf "$tmp" 2>/dev/null || true
    return 1
  fi
  if [ -e "$dst" ] && ! mv "$dst" "$tmp/old" 2>/dev/null; then
    rm -rf "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv "$tmp/new" "$dst" 2>/dev/null; then
    [ -e "$tmp/old" ] && mv "$tmp/old" "$dst" 2>/dev/null   # put the old one back
    rm -rf "$tmp" 2>/dev/null || true
    return 1
  fi
  rm -rf "$tmp" 2>/dev/null || true
  return 0
}

# --- discovery --------------------------------------------------------------

# lockfile_in <dir>: the dependency lockfile in <dir>, or empty. The name also
# selects the package manager (install_cmd).
lockfile_in() {  # <dir>
  local dir=$1 f
  for f in pnpm-lock.yaml package-lock.json yarn.lock; do
    if [ -f "$dir/$f" ]; then
      printf '%s' "$f"
      return 0
    fi
  done
  return 1
}

# discover_roots <worktree>: the install roots, one relative subpath per line,
# "." for the worktree root itself. See the header for the rule and why a bare
# package.json below the root does not qualify.
discover_roots() {  # <worktree>
  local wt=$1 dir rel seen=""
  [ -f "$wt/package.json" ] && { printf '.\n'; seen=" . "; }
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    rel=${dir#"$wt"/}
    [ "$rel" = "$dir" ] && rel=.
    case " $seen " in *" $rel "*) continue ;; esac
    seen="$seen $rel "
    printf '%s\n' "$rel"
  done < <(
    find "$wt" -maxdepth "$FM_PROVISION_MAX_DEPTH" \
      \( -name node_modules -o -name .git \) -prune -o \
      \( -name pnpm-lock.yaml -o -name package-lock.json -o -name yarn.lock \) -print 2>/dev/null |
      while IFS= read -r f; do dirname "$f"; done | sort -u
  )
}

# install_cmd <dir>: how THIS root installs. The lockfile names the package
# manager; with no lockfile at all, npm is the only one that can resolve from a
# bare package.json.
install_cmd() {  # <dir>
  local lock
  lock=$(lockfile_in "$1" 2>/dev/null || true)
  case "$lock" in
    pnpm-lock.yaml) printf 'pnpm install --prefer-offline' ;;
    yarn.lock) printf 'yarn install' ;;
    *) printf 'npm install' ;;
  esac
}

# uses_pnpm <dir>: pnpm hardlinks from its own global store, so its node_modules
# already costs almost nothing and cloning it buys nothing. Reconcile only.
uses_pnpm() {  # <dir>
  [ -f "$1/pnpm-lock.yaml" ]
}

# fingerprint <dir>: what makes a cached tree right or stale - the manifest and
# the lockfile, nothing else. Content, not mtime: a checkout writes fresh mtimes
# on identical bytes, which would expire the cache on every single slot reset.
fingerprint() {  # <dir>
  local dir=$1 f
  for f in package.json package-lock.json pnpm-lock.yaml yarn.lock; do
    [ -f "$dir/$f" ] && cksum < "$dir/$f" 2>/dev/null
  done | cksum | awk '{print $1}'
}

# --- the cache --------------------------------------------------------------

# pool_key_of <resolved-worktree>: the pool this worktree belongs to, or a refusal
# with a reason in POOL_WHY. This is the guard that keeps an installer out of
# projects/<repo>, so it verifies CONTAINMENT and SHAPE rather than deriving a name
# from whatever it was handed: the path must resolve inside the treehouse root and
# be exactly <pool>/<slot>/<repo> below it, with a numeric slot, which is how
# treehouse lays a pool out. The pool directory's own name - treehouse derives one
# per repo - is then a stable, collision-free key needing no knowledge of where the
# project clone is.
POOL_WHY=""
pool_key_of() {  # <resolved-worktree>
  local wt=$1 root rest pool slot repo
  POOL_WHY=""
  root=$(cd "$TREEHOUSE_ROOT" 2>/dev/null && pwd -P) || {
    POOL_WHY="the treehouse root $TREEHOUSE_ROOT does not exist"
    return 1
  }
  case "$wt/" in
    "$root"/*) ;;
    *) POOL_WHY="$wt is not inside the treehouse root $root"; return 1 ;;
  esac
  rest=${wt#"$root"/}
  pool=${rest%%/*}
  rest=${rest#*/}
  slot=${rest%%/*}
  repo=${rest#*/}
  if [ "$pool" = "$rest" ] || [ "$slot" = "$repo" ] || [ -z "$repo" ]; then
    POOL_WHY="$wt is under the treehouse root but is not a <pool>/<slot>/<repo> slot"
    return 1
  fi
  case "$repo" in
    */*) POOL_WHY="$wt is deeper than a treehouse slot"; return 1 ;;
  esac
  case "$slot" in
    ''|*[!0-9]*) POOL_WHY="'$slot' is not a treehouse slot number"; return 1 ;;
  esac
  printf '%s' "$pool"
}

# --- keeping the slot clean --------------------------------------------------

# git_worktree <dir>: is this a git worktree with a HEAD to restore from? A slot
# always is; a hand-run against something else may not be, and that is not an error.
git_worktree() {  # <dir>
  git -C "$1" rev-parse --verify -q HEAD >/dev/null 2>&1
}

# tracked_modified <worktree>: every TRACKED path the slot currently reports as
# modified, one per line.
#
# It has to be `git status`, not `git diff --name-only HEAD`, because the two
# disagree on exactly the case that bricks slots in practice. Verified on optiroq
# (2026-07-30): its .gitattributes sets `text=auto eol=lf`, npm rewrote
# src/admin-app/package-lock.json with CRLF, and `git diff` - which normalizes line
# endings before comparing - reported NO change, while `git status` reported ` M`
# and treehouse retired the slot as dirty. A restore keyed on diff saw nothing to
# do and left the slot bricked. `git checkout HEAD -- <path>` still repairs it: it
# rewrites the file from the blob regardless of what diff thinks.
#
# -z so git never quotes an exotic name into something checkout cannot take back;
# --no-renames so every record carries exactly one path; untracked files excluded
# because treehouse's own `git clean -fd` removes those on the return, so they
# never make a slot dirty.
tracked_modified() {  # <worktree>
  git -C "$1" status --porcelain -z --untracked-files=no --no-renames 2>/dev/null \
    | tr '\0' '\n' | sed 's/^...//'
}

# restore_tracked <worktree> <before-list-file>: undo the tracked-file edits THIS
# provision caused, and nothing else. The header owns why it has to happen at all
# (a dirty slot is retired from the pool permanently). Only paths that were clean
# when we started are restored - a blanket `git checkout -- .` would discard
# whatever was already in the slot, which is exactly the destructive move firstmate
# must never make. Prints the count restored, or nothing.
restore_tracked() {  # <worktree> <before-list-file>
  local wt=$1 before=$2 p n=0
  [ -n "$wt" ] && [ -f "$before" ] || return 0
  git_worktree "$wt" || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    grep -qxF -- "$p" "$before" && continue   # already modified before we ran
    git -C "$wt" checkout HEAD -- "$p" 2>/dev/null && n=$((n + 1))
  done < <(tracked_modified "$wt")
  [ "$n" -gt 0 ] && printf '%s' "$n"
  return 0
}

cache_root() {  # <pool-key>
  printf '%s/.fm-dep-cache/%s' "$TREEHOUSE_ROOT" "$1"
}

cache_entry() {  # <pool-key> <subpath>
  printf '%s/%s' "$(cache_root "$1")" "$2"
}

# cache_has <cache-entry>: is there anything to clone from?
cache_has() {  # <cache-entry>
  [ -d "$1/node_modules" ]
}

# cache_fresh <cache-entry> <fingerprint>: does the cached tree still match this
# root's manifest and lockfile? This gates only whether the cache is RE-SEEDED,
# never whether it is cloned from. A stale cached tree is still the right thing
# to start from - `npm install` reconciles it, and adding the missing packages to
# a nearly-right tree is far cheaper than building one from nothing.
cache_fresh() {  # <cache-entry> <fingerprint>
  cache_has "$1" || return 1
  [ "$(cat "$1/.fingerprint" 2>/dev/null || true)" = "$2" ]
}

# harvest_one <worktree> <subpath> <pool-key> [fingerprint]: copy a CORRECT
# node_modules into the cache. Clone-only: a harvest that fell back to a real copy
# would write the whole tree a second time for real, which is the disk cost this
# exists to avoid.
#
# The caller passes the fingerprint it took BEFORE reconciling, because that is
# the state a later slot will present: a fresh checkout carries the lockfile git
# has, not the one npm rewrote during the install. Storing the post-install
# fingerprint instead would never match, and every warm would re-harvest.
harvest_one() {  # <worktree> <subpath> <pool-key> [fingerprint]
  local wt=$1 rel=$2 key=$3 fp=${4:-} dir entry
  dir=$wt/$rel
  [ -d "$dir/node_modules" ] || return 1
  entry=$(cache_entry "$key" "$rel")
  [ -n "$fp" ] || fp=$(fingerprint "$dir")
  clone_tree "$dir/node_modules" "$entry/node_modules" || return 1
  printf '%s\n' "$fp" > "$entry/.fingerprint" 2>/dev/null || true
  return 0
}

# --- provisioning -----------------------------------------------------------

# budget_secs: how long the NEXT install may run. With FM_PROVISION_DEADLINE set
# (an epoch second; bin/fm-pool-warm.sh sets it), every root shares ONE budget, so
# a three-root project cannot silently take three times the bound its caller was
# given while holding that caller's treehouse lease and pool lock. Unset - a hand
# run - falls back to the per-install warm timeout.
budget_secs() {
  local left
  if [ -n "${FM_PROVISION_DEADLINE:-}" ]; then
    left=$(( FM_PROVISION_DEADLINE - $(date +%s) ))
    [ "$left" -gt 0 ] || { printf '0'; return 0; }
    printf '%s' "$left"
    return 0
  fi
  fm_pool_warm_timeout
}

out_of_time() { [ "$(budget_secs)" -le 0 ]; }

# reconcile <dir>: the project's own installer, which is what makes a cloned tree
# CORRECT rather than merely present. Bounded, because a hung install on the warm
# path holds a treehouse lease and a pool lock (bin/fm-pool-warm.sh's header owns
# that reasoning).
reconcile() {  # <dir>
  local dir=$1 cmd secs
  cmd=$(install_cmd "$dir")
  secs=$(budget_secs)
  [ "$secs" -gt 0 ] || return 1
  (cd "$dir" && fm_pool_run_bounded "$secs" sh -c "$cmd" >/dev/null 2>&1)
}

# provision_root <worktree> <subpath> <pool-key> <clone-ok>
# Clone what the cache has, reconcile always, then refresh the cache when this
# root's fingerprint has moved on. Prints one line per root: the operator wants
# to see WHICH path each root took, because "cloned" and "cold" have very
# different costs and a silent script hides a cache that never warms.
provision_root() {  # <worktree> <subpath> <pool-key> <clone-ok>
  local wt=$1 rel=$2 key=$3 clone_ok=$4 dir entry fp cloned=no started elapsed
  dir=$wt/$rel
  entry=$(cache_entry "$key" "$rel")
  fp=$(fingerprint "$dir")
  started=$(date +%s)

  # Say so rather than start an install with no time left to finish in: a root
  # abandoned mid-install is worse than one never begun.
  if out_of_time; then
    say "  $rel: skipped, the warm's time budget is spent (slot stays cold here)"
    return 1
  fi

  if uses_pnpm "$dir"; then
    reconcile "$dir" || { say "  $rel: pnpm install FAILED (slot stays cold here)"; return 1; }
    say "  $rel: pnpm store (no clone needed), reconciled in $(( $(date +%s) - started ))s"
    return 0
  fi

  if [ -d "$dir/node_modules" ]; then
    cloned=already   # a warm slot being re-warmed; its tree is already here
  elif [ "$clone_ok" = yes ] && cache_has "$entry"; then
    if clone_tree "$entry/node_modules" "$dir/node_modules"; then
      cloned=yes
    else
      say "  $rel: clone from the cache failed; installing cold instead"
    fi
  fi

  if ! reconcile "$dir"; then
    say "  $rel: install FAILED after clone=$cloned (slot stays cold here)"
    return 1
  fi
  elapsed=$(( $(date +%s) - started ))

  # Refresh the cache from what we just proved correct. Only when it is missing
  # or stale, so a steady-state warm rewrites nothing.
  if [ "$clone_ok" = yes ] && ! cache_fresh "$entry" "$fp"; then
    if harvest_one "$wt" "$rel" "$key" "$fp"; then
      say "  $rel: clone=$cloned, reconciled in ${elapsed}s, cache seeded"
      return 0
    fi
    say "  $rel: clone=$cloned, reconciled in ${elapsed}s, cache seed FAILED"
    return 0
  fi
  say "  $rel: clone=$cloned, reconciled in ${elapsed}s"
  return 0
}

# --- entry point ------------------------------------------------------------

usage() {
  echo "usage: fm-worktree-provision.sh <worktree-path> [--harvest]" >&2
  echo "       fm-worktree-provision.sh --probe <src-dir> [<dst-dir>]" >&2
}

# What the cleanup must undo, as globals, because a signal handler cannot see a
# `local` in main - the same reason bin/fm-pool-warm.sh keeps its lease global.
RESTORE_WT=""
RESTORE_BEFORE=""

# cleanup: leave the slot exactly as clean as we found it, then drop the lock.
# Restoring FIRST matters on the kill path: the lock is worthless next to a slot
# treehouse will never hand out again.
cleanup() {
  local n
  n=$(restore_tracked "$RESTORE_WT" "$RESTORE_BEFORE")
  [ -n "$n" ] && say "  restored $n tracked file(s) the installer rewrote - a warmed slot must come back clean, not dirty"
  [ -n "$RESTORE_BEFORE" ] && rm -f "$RESTORE_BEFORE" 2>/dev/null
  RESTORE_WT=""
  RESTORE_BEFORE=""
  fm_pool_lock_release
}

main() {
  local wt mode=provision key roots clone_ok=no rel rc=0 lock_base

  case "${1:-}" in
    ''|-h|--help) usage; return 2 ;;
    --probe)
      [ -n "${2:-}" ] || { usage; return 2; }
      if can_clone "$2" "${3:-$2}"; then say "clone: supported"; return 0; fi
      say "clone: unsupported - $CLONE_WHY"
      return 1
      ;;
  esac

  wt=$(cd "$1" 2>/dev/null && pwd -P) || { echo "error: no such worktree: $1" >&2; return 2; }
  case "${2:-}" in
    '') ;;
    --harvest) mode=harvest ;;
    *) usage; return 2 ;;
  esac

  # Rail 1 of AGENTS.md lives here in code: nothing outside a pooled worktree is
  # ever installed into. A refusal is a FAILURE to report, not a quiet success -
  # the caller asked for a warm slot and did not get one.
  key=$(pool_key_of "$wt") || {
    say "provision: refusing - $POOL_WHY. Only a pooled worktree is ever provisioned"
    return 1
  }
  roots=$(discover_roots "$wt")
  if [ -z "$roots" ]; then
    say "provision: no dependency roots found under $wt; nothing to do"
    return 0
  fi

  # The cache is shared by every firstmate home pointing at this pool, so a
  # refresh must not race another warmer's. fm-pool-lib.sh owns the locking
  # contract; do not re-roll one here.
  lock_base="$TREEHOUSE_ROOT/.fm-warm-locks/dep-cache-$key"
  fm_pool_lock_acquire "$lock_base" || {
    say "provision: another provisioner holds this pool's cache; this slot stays cold"
    return 1
  }
  # A signal handler that only releases and RETURNS lets the script carry on
  # cloning and installing with its lock already gone - so each handler exits, and
  # clears the EXIT trap first so the cleanup runs exactly once.
  trap cleanup EXIT
  trap 'trap - EXIT; cleanup; exit 130' INT
  trap 'trap - EXIT; cleanup; exit 143' TERM

  if can_clone "$TREEHOUSE_ROOT" "$wt"; then
    clone_ok=yes
  else
    say "provision: no copy-on-write clone is possible here ($CLONE_WHY); installing without cloning"
  fi

  if [ "$mode" = harvest ]; then
    if [ "$clone_ok" != yes ]; then
      say "provision: cannot harvest without clone support; nothing cached"
      return 1
    fi
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if harvest_one "$wt" "$rel" "$key"; then
        say "  $rel: harvested into the cache"
      else
        say "  $rel: nothing to harvest"
      fi
    done <<EOF
$roots
EOF
    return 0
  fi

  # Record which tracked files were ALREADY modified before the installer runs, so
  # cleanup restores only what this run dirtied. Without the snapshot a warm would
  # revert a crew's own edits; without the restore the slot comes back `dirty` and
  # treehouse can never hand it out again. See the header's clean-slot contract.
  if git_worktree "$wt"; then
    RESTORE_BEFORE=$(mktemp "${TMPDIR:-/tmp}/fm-provision-before.XXXXXX" 2>/dev/null) || RESTORE_BEFORE=""
    if [ -n "$RESTORE_BEFORE" ]; then
      tracked_modified "$wt" > "$RESTORE_BEFORE" 2>/dev/null || true
      RESTORE_WT=$wt
    else
      say "provision: cannot snapshot this slot's tracked state; refusing rather than risk leaving it dirty"
      return 1
    fi
  fi

  say "provision: $wt (pool $key)"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    provision_root "$wt" "$rel" "$key" "$clone_ok" || rc=1
  done <<EOF
$roots
EOF

  [ "$rc" -eq 0 ] || say "provision: finished with at least one cold root"
  return $rc
}

main "$@"
