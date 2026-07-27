#!/usr/bin/env bash
# fm-worktree-provision.sh - populate a pooled worktree's dependency trees by
# APFS CLONE from a per-pool cache, then reconcile with the project's own
# installer. THIS HEADER IS THE SINGLE OWNER OF THE PROVISIONING CONTRACT.
#
# Usage: fm-worktree-provision.sh <worktree-path>   provision it (clone + reconcile)
#        fm-worktree-provision.sh <worktree-path> --harvest
#                                                  only refresh the cache FROM it
#        fm-worktree-provision.sh --probe <dir>    print whether <dir>'s volume
#                                                  supports cloning, and exit
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
# DEGRADING IS DETECTED, NEVER ASSUMED. `cp -c` needs APFS; a non-APFS volume or
# a non-macOS cp does not have it. can_clone PROBES the destination with a real
# one-byte clone rather than testing the OS name. When the probe fails, the clone
# is SKIPPED and the plain install runs - never a `cp -R`, which would copy every
# byte for real and double the very disk this script exists to save.
#
# pnpm IS ALREADY BETTER THAN THIS and is left alone: it hardlinks from a global
# store, so its node_modules is near-zero on disk already and cloning it would add
# nothing. pnpm roots reconcile only.
#
# ALWAYS EXITS 0 for a failed provision, and says why. It runs on the warm path
# (background, on firstmate's time) and, if ever wired as a treehouse post_create
# hook, on the spawn path. A slot that failed to pre-warm is merely cold - the
# crew installs for itself, as it always did - and that must never fail a warm,
# leak a lease, or wake the user. A usage error still exits 2.
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

# can_clone <dir>: can this volume clone with `cp -c`? PROBED, not assumed - the
# answer is a property of the destination's filesystem (APFS yes, HFS+/exFAT/a
# network mount no) and of cp itself (GNU cp has no -c at all), and neither is
# readable from `uname`. One real clone of one real byte answers all of it.
can_clone() {  # <dir>
  local dir=$1 probe rc=0
  probe=$(mktemp -d "$dir/.fm-clone-probe.XXXXXX" 2>/dev/null) || return 1
  printf 'x' > "$probe/src" 2>/dev/null || { rm -rf "$probe"; return 1; }
  cp -c "$probe/src" "$probe/dst" 2>/dev/null || rc=1
  rm -rf "$probe" 2>/dev/null || true
  return $rc
}

# clone_tree <src-dir> <dst-dir>: CoW-clone a whole directory. Returns non-zero
# without leaving a partial tree behind, so a caller can fall back to a plain
# install and never hand a crew a half-populated node_modules.
clone_tree() {  # <src-dir> <dst-dir>
  local src=$1 dst=$2
  [ -d "$src" ] || return 1
  mkdir -p "$(dirname "$dst")" 2>/dev/null || return 1
  rm -rf "$dst" 2>/dev/null || true
  if cp -c -R "$src" "$dst" 2>/dev/null; then
    return 0
  fi
  rm -rf "$dst" 2>/dev/null || true
  return 1
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

# pool_key_of <worktree>: the pool this worktree belongs to. A slot lives at
# <pool>/<slot>/<repo>, so the pool directory's own name - which treehouse
# already derives per repo - is a stable, collision-free key, and needs no
# knowledge of where the project clone is.
pool_key_of() {  # <worktree>
  local wt=$1 pool
  pool=$(cd "$wt/../.." 2>/dev/null && pwd -P) || return 1
  [ -n "$pool" ] || return 1
  basename "$pool"
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

# harvest_one <worktree> <subpath> <pool-key>: copy a CORRECT node_modules into
# the cache. Clone-only: a harvest that fell back to a real copy would write the
# whole tree a second time for real, which is the disk cost this exists to avoid.
harvest_one() {  # <worktree> <subpath> <pool-key>
  local wt=$1 rel=$2 key=$3 dir entry fp
  dir=$wt/$rel
  [ -d "$dir/node_modules" ] || return 1
  entry=$(cache_entry "$key" "$rel")
  fp=$(fingerprint "$dir")
  clone_tree "$dir/node_modules" "$entry/node_modules" || return 1
  printf '%s\n' "$fp" > "$entry/.fingerprint" 2>/dev/null || true
  return 0
}

# --- provisioning -----------------------------------------------------------

# reconcile <dir>: the project's own installer, which is what makes a cloned tree
# CORRECT rather than merely present. Bounded, because a hung install on the warm
# path holds a treehouse lease and a pool lock (bin/fm-pool-warm.sh's header owns
# that reasoning).
reconcile() {  # <dir>
  local dir=$1 cmd secs
  cmd=$(install_cmd "$dir")
  secs=$(fm_pool_warm_timeout)
  if command -v timeout >/dev/null 2>&1; then
    (cd "$dir" && timeout "$secs" sh -c "$cmd" >/dev/null 2>&1)
  else
    (cd "$dir" && sh -c "$cmd" >/dev/null 2>&1)
  fi
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
    if harvest_one "$wt" "$rel" "$key"; then
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
  echo "       fm-worktree-provision.sh --probe <dir>" >&2
}

main() {
  local wt mode=provision key roots clone_ok=no rel rc=0 lock_base

  case "${1:-}" in
    ''|-h|--help) usage; return 2 ;;
    --probe)
      [ -n "${2:-}" ] || { usage; return 2; }
      if can_clone "$2"; then say "clone: supported"; return 0; fi
      say "clone: unsupported"
      return 1
      ;;
  esac

  wt=$(cd "$1" 2>/dev/null && pwd -P) || { echo "error: no such worktree: $1" >&2; return 2; }
  case "${2:-}" in
    '') ;;
    --harvest) mode=harvest ;;
    *) usage; return 2 ;;
  esac

  key=$(pool_key_of "$wt") || { say "provision: $wt is not inside a treehouse pool; nothing to do"; return 0; }
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
    say "provision: another provisioner holds this pool's cache; skipping"
    return 0
  }
  trap fm_pool_lock_release EXIT INT TERM

  if can_clone "$TREEHOUSE_ROOT"; then
    clone_ok=yes
  else
    say "provision: this volume does not support cp -c clones (not APFS?); installing without cloning"
  fi

  if [ "$mode" = harvest ]; then
    if [ "$clone_ok" != yes ]; then
      say "provision: cannot harvest without clone support; nothing cached"
      return 0
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

  say "provision: $wt (pool $key)"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    provision_root "$wt" "$rel" "$key" "$clone_ok" || rc=1
  done <<EOF
$roots
EOF

  [ "$rc" -eq 0 ] || say "provision: finished with at least one cold root"
  return 0
}

main "$@"
