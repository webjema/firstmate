#!/usr/bin/env bash
# fm-mem-lib.sh - memory admission for work firstmate adds to the box: a crew
# spawn waits for free memory, and a pool warm skips its pass, while MemAvailable
# sits below a reserve. Sourced by bin/fm-spawn.sh and bin/fm-pool-warm.sh.
#
# WHY. On 2026-10-07 MemAvailable on the 15.6 GB box fell to 1.2 GB: crew panes
# peak at a median 2.4 GB and up to 11.6 GB, and nothing stopped one more crew or
# one more npm install starting into that shortage.
#
# QUEUE, NEVER REFUSE. fm_mem_wait_for_reserve waits, then launches anyway once
# its bound passes and says so - a spawn never fails for memory. An unreadable
# meminfo (no /proc on macOS) reads as "enough": admission is a courtesy to the
# box, never a gate.
#
# docs/configuration.md owns the knobs; FM_MEMINFO (default /proc/meminfo) is the
# test seam.

# fm_mem_available_kb: MemAvailable in kB, or non-zero when it cannot be read.
fm_mem_available_kb() {
  local kb
  kb=$(awk '$1 == "MemAvailable:" { print $2; exit }' "${FM_MEMINFO:-/proc/meminfo}" 2>/dev/null)
  case "$kb" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$kb"
}

# fm_mem_int <value> <default>: a positive decimal integer, leading zeros read as
# decimal (bash arithmetic would read 08 as bad octal); anything else is the default.
fm_mem_int() {  # <value> <default>
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2"; return ;; esac
  if [ $(( 10#$1 )) -gt 0 ]; then printf '%s' $(( 10#$1 )); else printf '%s' "$2"; fi
}

# fm_mem_reserve_gb <config-dir>: precedence FM_MEM_RESERVE_GB, config/mem-reserve-gb, 4.
fm_mem_reserve_gb() {  # <config-dir>
  local value="${FM_MEM_RESERVE_GB:-}"
  if [ -z "$value" ] && [ -f "$1/mem-reserve-gb" ]; then
    value=$(tr -d '[:space:]' < "$1/mem-reserve-gb" 2>/dev/null || true)
  fi
  fm_mem_int "$value" 4
}

fm_mem_gb() {  # <kb>
  awk -v kb="${1:-0}" 'BEGIN { printf "%.1f", kb / 1048576 }'
}

# fm_mem_short <config-dir>: succeeds when MemAvailable is below the reserve, and
# prints "<available-GB> <reserve-GB>" for the caller's message.
fm_mem_short() {  # <config-dir>
  local avail reserve_gb
  avail=$(fm_mem_available_kb) || return 1
  reserve_gb=$(fm_mem_reserve_gb "$1")
  [ "$avail" -lt $(( reserve_gb * 1048576 )) ] || return 1
  printf '%s %s' "$(fm_mem_gb "$avail")" "$reserve_gb"
}

# fm_mem_wait_for_reserve <config-dir> <what>: block while memory is short, one
# line to stderr when the wait starts and one when it ends. Always returns 0.
fm_mem_wait_for_reserve() {  # <config-dir> <what>
  local config=$1 what=$2 short max poll waited=0
  max=$(fm_mem_int "${FM_SPAWN_MEM_WAIT_MAX:-}" 1800)
  poll=$(fm_mem_int "${FM_SPAWN_MEM_POLL:-}" 30)
  short=$(fm_mem_short "$config") || return 0
  echo "mem-wait: $what waiting for memory: ${short% *} GB available, below the ${short#* } GB reserve; re-checking every ${poll}s for up to ${max}s" >&2
  while [ "$waited" -lt "$max" ]; do
    sleep "$poll"
    waited=$(( waited + poll ))
    if ! short=$(fm_mem_short "$config"); then
      echo "mem-wait: $what memory freed after ${waited}s; launching" >&2
      return 0
    fi
  done
  echo "mem-wait: $what still short after ${waited}s (${short% *} GB available, ${short#* } GB reserve); launching anyway" >&2
  return 0
}

# fm_mem_crew_high <config-dir>: the per-crew MemoryHigh value, or empty when
# disabled. Precedence FM_CREW_MEMORY_HIGH, config/crew-memory-high, 8G; 0 or off
# disables. MemoryHigh throttles a crew past it, it never kills one (MemoryMax would).
fm_mem_crew_high() {  # <config-dir>
  local value=8G
  if [ -n "${FM_CREW_MEMORY_HIGH+x}" ]; then
    value=$FM_CREW_MEMORY_HIGH
  elif [ -f "$1/crew-memory-high" ]; then
    value=$(tr -d '[:space:]' < "$1/crew-memory-high" 2>/dev/null || true)
  fi
  case "$value" in
    ''|0|off) return 0 ;;
  esac
  if ! printf '%s' "$value" | grep -Eq '^[0-9]+[KMGT]?$'; then
    echo "warning: crew MemoryHigh '$value' is not a size like 8G; crews launch without a memory cap" >&2
    return 0
  fi
  printf '%s' "$value"
}

# fm_mem_scope_prefix <config-dir>: a launch prefix that runs the crew in its own
# user systemd scope with MemoryHigh, or empty when disabled or the box cannot
# make a user scope (no systemd, no user manager). `systemd-run --scope` execs the
# command in place, so the pane's process tree, its command name, and teardown's
# window kill all see the crew exactly as without it. `env` carries the launch
# template's VAR=value prefixes, which systemd-run itself would not parse.
# The probe runs here but the launch runs in the pane, whose environment is the
# tmux server's; the prefix pins the user-bus variables the probe succeeded with,
# so a pane without them still reaches the same user manager.
fm_mem_scope_prefix() {  # <config-dir>
  local high bounded=() pin='' v
  high=$(fm_mem_crew_high "$1")
  [ -n "$high" ] || return 0
  command -v systemd-run >/dev/null 2>&1 || return 0
  command -v timeout >/dev/null 2>&1 && bounded=(timeout 10)
  ${bounded[@]+"${bounded[@]}"} systemd-run --user --scope --quiet -p "MemoryHigh=$high" true >/dev/null 2>&1 || return 0
  for v in XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS; do
    [ -n "${!v:-}" ] && pin="$pin$v=$(printf '%q' "${!v}") "
  done
  printf '%ssystemd-run --user --scope --quiet -p MemoryHigh=%s env ' "$pin" "$high"
}
