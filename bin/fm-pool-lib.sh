#!/usr/bin/env bash
# fm-pool-lib.sh - the single owner of "what does firstmate know about a treehouse
# pool". Sourced by bin/fm-pool-warm.sh and bin/fm-pool-status.sh.
#
# treehouse (the external Go binary) owns the pool; firstmate only READS it, and
# reads it exactly one way: `treehouse status` run inside the project clone. That
# output is the structured contract, verified against treehouse v2.0.0 on
# 2026-07-14:
#
#   1     available    ~/.treehouse/optiroq-80b6c6/1/optiroq
#   2     leased       ~/.treehouse/optiroq-80b6c6/2/optiroq  (held by fm-warm-optiroq)
#   3     in-use       ~/.treehouse/optiroq-80b6c6/3/optiroq
#                      bash (1620624), claude (1620863), npm exec (1620891)
#   4     dirty        ~/.treehouse/optiroq-80b6c6/4/optiroq
#
# A slot line starts with the slot NAME; the indented continuation lines under an
# in-use slot list its processes and are not slots. Paths are ~-abbreviated.
#
# DIRTY IS THE ONE THAT BITES (verified, 2026-07-14): `treehouse get` SKIPS a
# dirty slot forever, and `treehouse prune` REFUSES to reclaim it ("Skipped 1
# unsafe idle worktree: uncommitted changes"). A crew that dies mid-task - three
# box reboots did exactly this - leaves its slot dirty, and the pool silently
# shrinks with nothing noticing. bin/fm-pool-status.sh exists to notice.
set -u

# fm_pool_key <project-real-path>: a stable, filesystem-safe slug for one POOL.
# Keyed by the project's physical path because that is what treehouse itself keys
# a pool by - so every firstmate home pointing at the same clone derives the same
# key, which is what makes the warm lock pool-scoped rather than home-scoped.
fm_pool_key() {  # <project-real-path>
  local path=$1 hash
  hash=$(printf '%s' "$path" | cksum | awk '{print $1}')
  printf '%s-%s' "$(basename "$path")" "$hash"
}

# fm_pool_read <project-real-path>: read the pool once. Returns 1 when treehouse
# cannot report on it at all (not a pool, treehouse missing/errored). On success
# sets:
#   FM_POOL_TABLE      one line per slot: "<name>\t<state>\t<path>\t<detail>"
#   FM_POOL_SLOTS      total slot count
#   FM_POOL_AVAILABLE  slots that are free AND warm - i.e. what a `treehouse get`
#                      could actually hand over right now
#   FM_POOL_DIR        the pool directory (parent of the slots), or empty
fm_pool_read() {  # <project-real-path>
  local project=$1 out line name state path detail
  out=$( (cd "$project" 2>/dev/null && treehouse status 2>/dev/null) ) || return 1
  FM_POOL_TABLE=""
  FM_POOL_SLOTS=0
  FM_POOL_AVAILABLE=0
  FM_POOL_DIR=""
  while IFS= read -r line; do
    # Slot lines start with the slot name in column 1; process/continuation lines
    # under an in-use slot are indented, and must never be counted as slots.
    case "$line" in
      ''|[[:space:]]*) continue ;;
    esac
    name=$(printf '%s' "$line" | awk '{print $1}')
    state=$(printf '%s' "$line" | awk '{print $2}')
    path=$(printf '%s' "$line" | awk '{print $3}')
    [ -n "$name" ] && [ -n "$state" ] && [ -n "$path" ] || continue
    case "$path" in
      '~'/*) path="$HOME/${path#'~'/}" ;;
      /*) ;;
      *) continue ;;   # not a slot line
    esac
    detail=$(printf '%s' "$line" | sed -n 's/.*(held by \([^)]*\)).*/\1/p')
    FM_POOL_SLOTS=$((FM_POOL_SLOTS + 1))
    [ "$state" = available ] && FM_POOL_AVAILABLE=$((FM_POOL_AVAILABLE + 1))
    [ -n "$FM_POOL_DIR" ] || FM_POOL_DIR=$(dirname "$(dirname "$path")")
    FM_POOL_TABLE="${FM_POOL_TABLE}${name}	${state}	${path}	${detail}
"
  done <<EOF
$out
EOF
  return 0
}

# fm_pool_max_trees <project-real-path>: treehouse's own pool ceiling. Its
# treehouse.toml owns the value; 16 is treehouse's documented default.
fm_pool_max_trees() {  # <project-real-path>
  local project=$1 value
  value=$(sed -n 's/^[[:space:]]*max_trees[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "$project/treehouse.toml" 2>/dev/null | head -n 1)
  case "${value:-}" in
    ''|*[!0-9]*) printf '16' ;;
    *) printf '%s' "$value" ;;
  esac
}

# fm_pool_disk_budget_gb <config-dir>: the per-project-pool disk ceiling, in GB.
# Precedence: FM_POOL_DISK_BUDGET_GB, then config/pool-disk-budget-gb, then 20.
# docs/configuration.md owns the knob.
fm_pool_disk_budget_gb() {  # <config-dir>
  local config=$1 value="${FM_POOL_DISK_BUDGET_GB:-}"
  if [ -z "$value" ] && [ -f "$config/pool-disk-budget-gb" ]; then
    value=$(tr -d '[:space:]' < "$config/pool-disk-budget-gb" 2>/dev/null || true)
  fi
  case "${value:-}" in
    ''|*[!0-9]*) printf '20' ;;
    *) printf '%s' "$value" ;;
  esac
}

# fm_pool_disk_budget_kb <config-dir>: the same ceiling in KB, which is the unit
# the check actually works in. FM_POOL_DISK_BUDGET_KB is an INTERNAL override so
# the behavior test can exercise the budget with a few small files instead of
# staging 20 GB; operators set the GB knob above.
fm_pool_disk_budget_kb() {  # <config-dir>
  local kb="${FM_POOL_DISK_BUDGET_KB:-}"
  case "$kb" in
    ''|*[!0-9]*) printf '%s' "$(( $(fm_pool_disk_budget_gb "$1") * 1024 * 1024 ))" ;;
    *) printf '%s' "$kb" ;;
  esac
}

# fm_pool_gb <kb>: kilobytes as GB with one decimal, for operator-facing numbers.
fm_pool_gb() {  # <kb>
  awk -v kb="${1:-0}" 'BEGIN { printf "%.1f", kb / 1048576 }'
}

# fm_pool_lease <project-real-path> <holder>: reserve a slot, creating-or-resetting
# it and running the post_create hook (i.e. installing deps). Prints its path.
# This IS the warm operation - treehouse does the work, firstmate does not
# reimplement any of it.
fm_pool_lease() {  # <project-real-path> <holder>
  (cd "$1" 2>/dev/null && treehouse get --lease --lease-holder "$2" 2>/dev/null)
}

# fm_pool_release <project-real-path> <slot-path>: release the lease. The slot's
# installed dependencies SURVIVE this (treehouse's reset is `git clean -fd`, no
# -x, so gitignored trees are kept) - which is what leaves it available AND warm.
fm_pool_release() {  # <project-real-path> <slot-path>
  (cd "$1" 2>/dev/null && treehouse return "$2" >/dev/null 2>&1)
}
