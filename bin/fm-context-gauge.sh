#!/usr/bin/env bash
# fm-context-gauge.sh - deterministic one-line read of a session's context pressure.
#
# The observability primitive of the context-management design (Layer 2 in
# docs/proposals/context-management.md): firstmate cannot keep a session under its
# window without seeing where the session sits. Same shape as fm-crew-state.sh -
# determinism in bash, one token-tight parseable line out, exit 0 on any successful
# read - so firstmate can read it cheaply and a script can grep the `level:` field.
#
# Usage:
#   fm-context-gauge.sh                 read the primary (this) session by its cwd
#   fm-context-gauge.sh --self          same, explicit
#   fm-context-gauge.sh <task-id>       read a crew's session (worktree from meta)
#   fm-context-gauge.sh --cwd <dir>     read whatever session runs in <dir>
#   -h, --help
#
# Output contract `fm-context-gauge.v1`, one line:
#   tokens: <n> · pct: <n> · level: <ok|high|critical|unknown> · source: <native|proxy|none> · <detail>
#
# `native` is a real measurement from the claude transcript; `proxy` is an estimate
# from the watcher-maintained event counter times a per-event token estimate; `none`
# means neither was available (unknown level), which is a valid read, not an error.
# Read-only; no locks, no mutation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-context-lib.sh
. "$SCRIPT_DIR/fm-context-lib.sh"

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
}

SEP=' · '
emit() {  # <tokens|-> <level> <source> [detail]
  local tokens=$1 level=$2 source=$3 detail=${4:-} pct=-
  if [ "$tokens" != "-" ]; then pct=$(fm_context_pct "$tokens"); fi
  local line="tokens: $tokens${SEP}pct: $pct${SEP}level: $level${SEP}source: $source"
  [ -n "$detail" ] && line="$line${SEP}$detail"
  printf '%s\n' "$line"
  exit 0
}

# --- resolve the target session (cwd + harness + proxy key) -----------------

TARGET=--self
CWD=""
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --self|"") TARGET=--self ;;
  --cwd) TARGET=--cwd; CWD=${2:-}; [ -n "$CWD" ] || { echo "usage: fm-context-gauge.sh --cwd <dir>" >&2; exit 2; } ;;
  --*) echo "fm-context-gauge.sh: unknown option $1" >&2; exit 2 ;;
  *) TARGET=$1 ;;
esac

HARNESS=""
PROXY_KEY=""
case "$TARGET" in
  --self)
    CWD=$PWD
    PROXY_KEY=self
    HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || echo unknown)
    ;;
  --cwd)
    PROXY_KEY=$(printf '%s' "$CWD" | tr ':/. ' '____')
    HARNESS=${FM_CONTEXT_HARNESS:-claude}
    ;;
  *)
    META="$STATE/$TARGET.meta"
    [ -f "$META" ] || emit - unknown none "no metadata for $TARGET"
    CWD=$(grep '^worktree=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    HARNESS=$(grep '^harness=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$HARNESS" ] || HARNESS=claude
    PROXY_KEY=$TARGET
    [ -n "$CWD" ] || emit - unknown none "no worktree recorded for $TARGET"
    ;;
esac

# --- native read (claude only), else proxy, else none -----------------------

if [ "$HARNESS" = claude ] && [ -n "$CWD" ]; then
  if T=$(fm_context_transcript_for_cwd "$CWD"); then
    if TOTAL=$(fm_context_transcript_total "$T"); then
      emit "$TOTAL" "$(fm_context_level "$TOTAL")" native "$(basename "$T")"
    fi
  fi
fi

PROXY_FILE="$STATE/.pressure-$PROXY_KEY"
if [ -n "$PROXY_KEY" ] && [ -f "$PROXY_FILE" ]; then
  COUNT=$(cat "$PROXY_FILE" 2>/dev/null || echo 0)
  case "$COUNT" in
    ''|*[!0-9]*) COUNT=0 ;;
  esac
  EST=$(( COUNT * $(fm_context_proxy_tpe) ))
  emit "$EST" "$(fm_context_level "$EST")" proxy "events=$COUNT"
fi

emit - unknown none "no transcript or counter for ${TARGET#--}"
