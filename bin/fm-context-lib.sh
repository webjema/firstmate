#!/usr/bin/env bash
# fm-context-lib.sh - shared context-pressure primitives (sourced, not run).
#
# The one owner of: how a session's context size is read, how the thresholds are
# resolved, and how a token count maps to a pressure level. bin/fm-context-gauge.sh
# is the CLI over these helpers; later phases (the watcher context-high surfacing,
# the helm-handoff reset) source the same helpers so the contract has one home.
# See docs/proposals/context-management.md for the layered design.
#
# NATIVE READ (verified for the claude harness). Every Claude Code transcript line
# records its own "cwd" and an assistant turn's "usage" object. The live context
# size of a session is the last usage total:
#     input_tokens + cache_creation_input_tokens + cache_read_input_tokens
# A session's transcript is discovered by matching the "cwd" field to the session's
# working directory (its own cwd for the primary, the worktree for a crew), never by
# reconstructing Claude Code's project-dir path munging, which is undocumented and
# fragile. Verified 2026-07-20 on claude-opus-4-8: a live session read 116738 tokens
# from input_tokens=2 + cache_creation=485 + cache_read=... matching its own turn.
#
# PROXY FLOOR (harnesses with no readable native usage). A per-session event counter
# at state/.pressure-<key> (written by the watcher in a later phase) times a
# configured per-event token estimate yields an approximate size. Reported with
# source=proxy so an estimate is never mistaken for a measurement.
#
# Read-only and side-effect free: these helpers never write state or mutate a fleet.

# --- threshold resolution ---------------------------------------------------
# Order: env override FM_CONTEXT_<KEY> -> config/context-management -> default.
# The config file carries `key=value` lines; blank and `#` lines are ignored.

fm_context_config_file() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-${FM_HOME:-${FM_ROOT:-.}}/config}/context-management"
}

fm_context_threshold() {  # <key> <default>
  local key=$1 def=$2 env_name val cfg
  env_name="FM_CONTEXT_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  val=${!env_name-}
  if [ -n "$val" ]; then printf '%s\n' "$val"; return 0; fi
  cfg=$(fm_context_config_file)
  if [ -f "$cfg" ]; then
    val=$(grep -E "^[[:space:]]*$key=" "$cfg" 2>/dev/null \
      | grep -vE '^[[:space:]]*#' \
      | tail -1 \
      | sed -E "s/^[[:space:]]*$key=[[:space:]]*//; s/[[:space:]].*//") || true
    if [ -n "$val" ]; then printf '%s\n' "$val"; return 0; fi
  fi
  printf '%s\n' "$def"
}

# Canonical defaults, tuned in Phase 0 once real distributions are known.
fm_context_soft()    { fm_context_threshold soft 120000; }
fm_context_hard()    { fm_context_threshold hard 160000; }
fm_context_ceiling() { fm_context_threshold ceiling 200000; }
fm_context_proxy_tpe() { fm_context_threshold proxy_tokens_per_event 1500; }

# ok below soft, high in [soft,hard), critical at/above hard.
fm_context_level() {  # <tokens>
  local t=$1 soft hard
  soft=$(fm_context_soft); hard=$(fm_context_hard)
  if [ "$t" -ge "$hard" ]; then printf 'critical\n'
  elif [ "$t" -ge "$soft" ]; then printf 'high\n'
  else printf 'ok\n'; fi
}

# percent of ceiling, integer, floor.
fm_context_pct() {  # <tokens>
  local t=$1 ceil
  ceil=$(fm_context_ceiling)
  [ "$ceil" -gt 0 ] || { printf '0\n'; return; }
  printf '%s\n' "$(( t * 100 / ceil ))"
}

# --- auto-compact launch env (claude) ---------------------------------------
# The CLI-native way to keep a firstmate-launched claude session under the managed
# ceiling: the Claude Code CLI does NOT expose the server-side clear_tool_uses
# context-editing feature (API/Agent-SDK only), but it DOES honor two env vars,
# verified against code.claude.com/docs/en/env-vars:
#   CLAUDE_CODE_AUTO_COMPACT_WINDOW  - treat the context window as this many tokens
#                                      for auto-compaction (default: the model's own
#                                      window, 200K or 1M), so a 1M model compacts as
#                                      if it were <ceiling>.
#   CLAUDE_AUTOCOMPACT_PCT_OVERRIDE  - fire auto-compaction at this percent (1-100)
#                                      of that window.
# Together they make a claude session auto-compact around <ceiling> * <pct>%, keeping
# it under the ceiling natively instead of only near the model's full window.
#
# Emits a trailing-space-terminated "KEY=val KEY=val " prefix suitable for prepending
# to a launch command, or empty when disabled (autocompact_pct outside 1-100, or a
# non-positive ceiling). Only the claude launch template consumes it.
fm_context_autocompact_env() {
  local ceil pct
  ceil=$(fm_context_ceiling)
  pct=$(fm_context_threshold autocompact_pct 90)
  case "$ceil" in ''|*[!0-9]*) return 0 ;; esac
  case "$pct" in ''|*[!0-9]*) return 0 ;; esac
  { [ "$ceil" -gt 0 ] && [ "$pct" -ge 1 ] && [ "$pct" -le 100 ]; } || return 0
  printf 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=%s CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=%s ' "$ceil" "$pct"
}

# --- native transcript read (claude) ----------------------------------------

fm_context_projects_dir() {
  printf '%s\n' "${FM_CONTEXT_PROJECTS_DIR:-$HOME/.claude/projects}"
}

# Portable file mtime in epoch seconds (GNU coreutils, then BSD/macOS).
fm_context_mtime() {  # <file>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Newest transcript whose recorded cwd matches <cwd> exactly. The trailing quote
# in the match string anchors exactness, so /a/b never matches /a/bc.
fm_context_transcript_for_cwd() {  # <cwd> -> path | rc1
  local cwd=$1 projects f m best="" bestm=0
  projects=$(fm_context_projects_dir)
  [ -d "$projects" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    m=$(fm_context_mtime "$f")
    if [ "$m" -gt "$bestm" ]; then bestm=$m; best=$f; fi
  done < <(grep -lF "\"cwd\":\"$cwd\"" "$projects"/*/*.jsonl 2>/dev/null)
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# Last usage total in a transcript. input_tokens is emitted first in the usage
# object and is never preceded by a quote inside cache_creation/cache_read, so the
# first match is the standalone field.
fm_context_transcript_total() {  # <jsonl> -> tokens | rc1
  local f=$1 line inp cc cr
  [ -f "$f" ] || return 1
  line=$(grep 'cache_read_input_tokens' "$f" 2>/dev/null | tail -1) || true
  [ -n "$line" ] || return 1
  inp=$(printf '%s\n' "$line" | grep -oE '"input_tokens":[0-9]+' | head -1 | grep -oE '[0-9]+') || true
  cc=$(printf '%s\n'  "$line" | grep -oE '"cache_creation_input_tokens":[0-9]+' | head -1 | grep -oE '[0-9]+') || true
  cr=$(printf '%s\n'  "$line" | grep -oE '"cache_read_input_tokens":[0-9]+' | head -1 | grep -oE '[0-9]+') || true
  inp=${inp:-0}; cc=${cc:-0}; cr=${cr:-0}
  printf '%s\n' "$(( inp + cc + cr ))"
}
