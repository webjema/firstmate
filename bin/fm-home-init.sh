#!/usr/bin/env bash
# Create or verify a BARE firstmate home: one instance's private state/, data/ and
# config/, and nothing else.
#
# It is the provisioning half of the shared-instance arrangement in
# docs/configuration.md - one checkout, one projects/ clone per repository and one
# worktree pool per host, with each instance carrying only what must be private.
# Everything else the instance needs it reaches through the shared checkout it is
# launched from, so a bare home holds no code, no clones and no worktrees.
#
# BARE IS LOAD-BEARING, not a size optimisation. bin/fm-wake-lib.sh's
# fm_home_lock_is_foreign refuses the home lock when $FM_HOME is a DIFFERENT firstmate
# checkout than the watcher was launched from - the containment that stops a watcher
# started inside a crew worktree from evicting the real home's. A home with no
# bin/fm-watch.sh of its own is not a checkout, so it never trips that predicate, which
# is exactly why several instances can share one checkout. `verify` therefore refuses a
# home that has grown a bin/, and the guard itself is not to be relaxed to accommodate
# anything: wanting to relax it means the home is the wrong shape.
#
# It is NOT bin/fm-home-seed.sh's job. That provisions a SECONDMATE home - a full
# checkout, leased from the pool, carrying a charter and a registry entry, reporting to
# a primary. A bare home is a peer primary: no charter, no marker, no registry line.
#
# The instance's environment is the other half of the arrangement, because
# FM_PROJECTS_OVERRIDE is read from the environment and a bare home cannot inject it.
# So `create` writes <home>/env.sh and the operator sources it before starting the
# session; docs/configuration.md owns the arrangement, this script owns the file.
#
# Usage: fm-home-init.sh <home-dir> [--projects <dir>]   create or refresh, then verify
#        fm-home-init.sh --verify <home-dir>             verify only
#        fm-home-init.sh --help
#
# <dir> defaults to the shared checkout's own projects/, which is the arrangement's
# default: the clones live once, beside the code every instance runs.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  cat >&2 <<'USAGE'
usage: fm-home-init.sh <home-dir> [--projects <dir>]   create or refresh a bare home
       fm-home-init.sh --verify <home-dir>             verify an existing one
       fm-home-init.sh --help
USAGE
}

MODE=create
HOME_ARG=""
PROJECTS_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --verify) MODE=verify ;;
    --projects)
      [ $# -ge 2 ] || { echo "error: --projects needs a directory" >&2; exit 1; }
      PROJECTS_ARG=$2
      shift
      ;;
    -*) echo "error: unknown flag $1" >&2; usage; exit 1 ;;
    *)
      [ -z "$HOME_ARG" ] || { echo "error: more than one home given" >&2; usage; exit 1; }
      HOME_ARG=$1
      ;;
  esac
  shift
done
[ -n "$HOME_ARG" ] || { usage; exit 1; }
[ "$MODE" = create ] || [ -z "$PROJECTS_ARG" ] || {
  echo "error: --projects is a create-time choice; --verify reads it back from env.sh" >&2
  exit 1
}

# Absolute, but NOT physically resolved: an operator who addresses the home through a
# symlink gets that spelling back in env.sh, and every script resolves consistently
# from it. Containment below compares resolved paths, where it matters.
abspath() {  # <path>
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$(pwd)" "$1" ;;
  esac
}
realpath_of() {  # <path> - resolved if it exists, unchanged if it does not
  local p=$1
  ( cd "$p" 2>/dev/null && pwd -P ) || printf '%s' "$p"
}

HOME_DIR=$(abspath "$HOME_ARG")
ENV_FILE="$HOME_DIR/env.sh"

problems=0
check_ok()   { printf 'ok:    %s\n' "$1"; }
check_fail() { printf 'error: %s\n' "$1" >&2; problems=$((problems + 1)); }

# --- verify -----------------------------------------------------------------

verify_home() {
  local projects real_home real_root d

  [ -d "$HOME_DIR" ] || { check_fail "$HOME_DIR does not exist"; return 0; }

  real_home=$(realpath_of "$HOME_DIR")
  real_root=$(realpath_of "$FM_ROOT")
  case "$real_home/" in
    "$real_root"/*) check_fail "the home is inside the shared checkout ($FM_ROOT); it would make the checkout dirty and cannot be shared" ;;
    *) check_ok "outside the shared checkout ($FM_ROOT)" ;;
  esac

  # The bareness check. Named for what it protects, because a future reader deleting
  # it will not otherwise know it is holding up the whole arrangement.
  if [ -e "$HOME_DIR/bin/fm-watch.sh" ]; then
    check_fail "the home carries its own bin/fm-watch.sh, so it is a checkout, not a bare home - its watcher would refuse the home lock as foreign (bin/fm-wake-lib.sh)"
  else
    check_ok "bare: no checkout of its own, so the watcher's foreign-home guard never fires"
  fi

  if [ -e "$HOME_DIR/.fm-secondmate-home" ]; then
    check_fail "the home is a secondmate home; bin/fm-home-seed.sh owns those, not this script"
  fi

  for d in state data config; do
    if [ ! -d "$HOME_DIR/$d" ]; then
      check_fail "$HOME_DIR/$d is missing"
    elif [ ! -w "$HOME_DIR/$d" ]; then
      check_fail "$HOME_DIR/$d is not writable"
    else
      check_ok "$d/ present and writable"
    fi
  done

  if [ ! -f "$ENV_FILE" ]; then
    check_fail "$ENV_FILE is missing; the instance has no way to set FM_PROJECTS_OVERRIDE"
    return 0
  fi
  projects=$(sed -n 's/^export FM_PROJECTS_OVERRIDE=//p' "$ENV_FILE" | tail -1 | sed 's/^"//; s/"$//')
  if [ -z "$projects" ]; then
    check_fail "$ENV_FILE names no FM_PROJECTS_OVERRIDE"
  elif [ ! -d "$projects" ]; then
    check_fail "the shared clones directory $projects does not exist"
  else
    check_ok "shared clones at $projects"
  fi
}

if [ "$MODE" = verify ]; then
  verify_home
  if [ "$problems" -gt 0 ]; then
    echo "fm-home-init: $HOME_DIR is not a usable bare home ($problems problem(s))" >&2
    exit 1
  fi
  echo "fm-home-init: $HOME_DIR verified"
  exit 0
fi

# --- create -----------------------------------------------------------------

PROJECTS=$(abspath "${PROJECTS_ARG:-$FM_ROOT/projects}")

# Refuse before creating anything, so a wrong argument leaves no half-built home.
if [ -e "$HOME_DIR/bin/fm-watch.sh" ] || [ -e "$HOME_DIR/AGENTS.md" ]; then
  echo "error: $HOME_DIR already holds a firstmate checkout; a bare home carries no code" >&2
  echo "       (a secondmate home is bin/fm-home-seed.sh's job)" >&2
  exit 1
fi
if [ -e "$HOME_DIR/.fm-secondmate-home" ]; then
  echo "error: $HOME_DIR is a secondmate home; bin/fm-home-seed.sh owns it" >&2
  exit 1
fi
real_home_pre=$(realpath_of "$(dirname "$HOME_DIR")")/$(basename "$HOME_DIR")
case "$real_home_pre/" in
  "$(realpath_of "$FM_ROOT")"/*)
    echo "error: $HOME_DIR is inside the shared checkout ($FM_ROOT); put it outside so the checkout stays clean" >&2
    exit 1
    ;;
esac

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
# Supplied rather than demanded: an empty shared clones directory is a fleet with no
# projects yet, which is a normal first run, not an error to report back.
mkdir -p "$PROJECTS"

cat > "$ENV_FILE" <<ENVFILE
# Environment for one bare firstmate instance. Source it before starting the session:
#   . $ENV_FILE && $FM_ROOT/bin/fm-session-start.sh
#
# Written by bin/fm-home-init.sh; re-run it to refresh. FM_ROOT is deliberately NOT
# set: every script resolves the checkout from its own location, so the checkout you
# launch from is the checkout you get, and this file cannot go stale against a move.
export FM_HOME="$HOME_DIR"
export FM_PROJECTS_OVERRIDE="$PROJECTS"
ENVFILE

verify_home
if [ "$problems" -gt 0 ]; then
  echo "fm-home-init: $HOME_DIR was created but does not verify ($problems problem(s))" >&2
  exit 1
fi

cat <<DONE
fm-home-init: bare home ready at $HOME_DIR
  code:    $FM_ROOT   (shared; nothing was written into it)
  clones:  $PROJECTS  (shared)
  start:   . $ENV_FILE && $FM_ROOT/bin/fm-session-start.sh
DONE
