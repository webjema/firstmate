#!/usr/bin/env bash
# Behavior tests for bin/fm-context-gauge.sh and bin/fm-context-lib.sh - the
# context-pressure observability primitive (Layer 2 of the context-management
# design). Hermetic: a fake ~/.claude/projects tree (FM_CONTEXT_PROJECTS_DIR), fake
# state/<id>.meta files, a fake config/context-management (FM_CONFIG_OVERRIDE), and a
# fake proxy counter. Nothing reads a real session or touches the live fleet.
#
# Cases:
#   (a) native read: total = input + cache_creation + cache_read, level classified
#   (b) newest transcript wins when two match the same cwd
#   (c) exact cwd match: /a/b never matches /a/bc
#   (d) thresholds from config file, and env override beating the file
#   (e) config parsing tolerates comments, blanks, and whitespace
#   (f) task-id path reads worktree+harness from meta; non-claude skips native
#   (g) proxy path: counter present -> source=proxy, tokens = count * per-event
#   (h) none path: no transcript and no counter -> unknown/none, exit 0
#   (i) missing meta / missing worktree -> unknown/none
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-context-lib.sh
. "$ROOT/bin/fm-context-lib.sh"

GAUGE="$ROOT/bin/fm-context-gauge.sh"
TMP=$(fm_test_tmproot fm-context-gauge)

PROJECTS="$TMP/projects"
STATE="$TMP/state"
CONFIG="$TMP/config"
mkdir -p "$PROJECTS" "$STATE" "$CONFIG"

export FM_CONTEXT_PROJECTS_DIR="$PROJECTS"
export FM_STATE_OVERRIDE="$STATE"
export FM_CONFIG_OVERRIDE="$CONFIG"

# Write one transcript jsonl carrying <cwd> and a usage turn summing to the three
# token fields. proj is a subdir name to mimic Claude Code's per-project folders.
write_transcript() {  # <proj> <file> <cwd> <input> <cache_creation> <cache_read>
  local proj=$1 file=$2 cwd=$3 inp=$4 cc=$5 cr=$6
  local d="$PROJECTS/$proj"
  mkdir -p "$d"
  printf '{"type":"user","cwd":"%s","message":{"role":"user"}}\n' "$cwd" > "$d/$file"
  printf '{"type":"assistant","cwd":"%s","message":{"role":"assistant","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":50}}}\n' \
    "$cwd" "$inp" "$cc" "$cr" >> "$d/$file"
}

field() {  # <line> <key>
  printf '%s\n' "$1" | sed -E "s/.*${2}: ([^·]*).*/\1/" | sed -E 's/[[:space:]]+$//'
}

# --- (a) native read + classification ---------------------------------------
write_transcript projA sess.jsonl /work/a 2 485 196077
out=$("$GAUGE" --cwd /work/a)
assert_contains "$out" "tokens: 196564" "native total sums the three usage fields"
assert_contains "$out" "source: native" "matched transcript reads native"
assert_contains "$out" "level: critical" "196564 >= hard default 160000 is critical"
pass "(a) native read sums usage and classifies critical"

# ok / high boundaries against defaults (soft 120000, hard 160000)
write_transcript projOk okc.jsonl /work/ok 0 0 90000
assert_contains "$("$GAUGE" --cwd /work/ok)" "level: ok" "90000 < soft is ok"
write_transcript projHi hic.jsonl /work/hi 0 0 130000
assert_contains "$("$GAUGE" --cwd /work/hi)" "level: high" "130000 in [soft,hard) is high"
pass "(a2) ok/high boundaries classify correctly"

# pct is percent of ceiling (default 200000): 90000 -> 45
assert_contains "$("$GAUGE" --cwd /work/ok)" "pct: 45" "pct is percent of ceiling"
pass "(a3) pct is percent of ceiling"

# --- (b) newest transcript wins ---------------------------------------------
write_transcript projB old.jsonl /work/b 0 0 10000
sleep 1
write_transcript projB new.jsonl /work/b 0 0 20000
out=$("$GAUGE" --cwd /work/b)
assert_contains "$out" "tokens: 20000" "newest transcript by mtime wins"
pass "(b) newest transcript wins for the same cwd"

# --- (c) exact cwd match ----------------------------------------------------
write_transcript projC c.jsonl /work/c 0 0 55000
# a longer path that has /work/c as a prefix must NOT be picked up by /work/c
write_transcript projCC cc.jsonl /work/cc 0 0 99000
out=$("$GAUGE" --cwd /work/c)
assert_contains "$out" "tokens: 55000" "exact cwd match, not the /work/cc prefix sibling"
pass "(c) cwd match is exact, prefix does not cross-match"

# --- (d) config thresholds + env override -----------------------------------
cat > "$CONFIG/context-management" <<'EOF'
# firstmate context-management thresholds
soft=50000
hard=80000
ceiling=100000
EOF
write_transcript projD d.jsonl /work/d 0 0 60000
out=$("$GAUGE" --cwd /work/d)
assert_contains "$out" "level: high" "config soft=50000 makes 60000 high"
assert_contains "$out" "pct: 60" "config ceiling=100000 makes 60000 -> 60%"
# env override beats the file
out=$(FM_CONTEXT_HARD=55000 "$GAUGE" --cwd /work/d)
assert_contains "$out" "level: critical" "env FM_CONTEXT_HARD overrides the config file"
pass "(d) thresholds resolve env > file > default"
rm -f "$CONFIG/context-management"

# --- (e) config parsing tolerance -------------------------------------------
cat > "$CONFIG/context-management" <<'EOF'

  # a comment
   soft =  ignored-wrong-syntax
soft=70000
hard=90000
EOF
# leading-space `soft =` (space before =) is not a match; the clean soft=70000 is.
assert_contains "$("$GAUGE" --cwd /work/d)" "level: ok" "60000 < configured soft 70000 is ok"
pass "(e) config parsing ignores comments/blanks and picks clean key=value"
rm -f "$CONFIG/context-management"

# --- (f) task-id path: meta worktree+harness; non-claude skips native --------
fm_write_meta "$STATE/claudetask.meta" "worktree=/work/a" "harness=claude" "kind=ship"
assert_contains "$("$GAUGE" claudetask)" "source: native" "claude task resolves worktree and reads native"
assert_contains "$("$GAUGE" claudetask)" "tokens: 196564" "claude task reads the /work/a transcript total"

fm_write_meta "$STATE/codextask.meta" "worktree=/work/a" "harness=codex" "kind=ship"
out=$("$GAUGE" codextask)
assert_contains "$out" "source: none" "non-claude harness skips the native transcript read"
assert_contains "$out" "level: unknown" "non-claude with no counter is unknown, not a fake number"
pass "(f) task path uses meta; non-claude skips native"

# --- (g) proxy floor --------------------------------------------------------
# Give the codex task a proxy counter; default per-event estimate is 1500 tokens.
printf '40\n' > "$STATE/.pressure-codextask"
out=$("$GAUGE" codextask)
assert_contains "$out" "source: proxy" "counter present -> proxy source"
assert_contains "$out" "tokens: 60000" "proxy tokens = events(40) * per-event(1500)"
assert_contains "$out" "events=40" "proxy detail reports the event count"
# per-event override via config
printf 'proxy_tokens_per_event=2000\n' > "$CONFIG/context-management"
assert_contains "$("$GAUGE" codextask)" "tokens: 80000" "config per-event estimate is honored"
pass "(g) proxy floor estimates from the event counter"
rm -f "$CONFIG/context-management" "$STATE/.pressure-codextask"

# --- (h) none path is a valid read, exit 0 ----------------------------------
if out=$("$GAUGE" --cwd /work/none-at-all); then rc=0; else rc=$?; fi
[ "$rc" -eq 0 ] || fail "none path must exit 0 (a valid read), got $rc"
assert_contains "$out" "source: none" "no transcript and no counter -> none"
assert_contains "$out" "level: unknown" "none read is unknown level"
pass "(h) none path is a valid read with exit 0"

# --- (i) missing meta / missing worktree ------------------------------------
assert_contains "$("$GAUGE" ghost-task)" "no metadata" "missing meta reports cleanly"
fm_write_meta "$STATE/nowt.meta" "harness=claude" "kind=ship"
assert_contains "$("$GAUGE" nowt)" "no worktree recorded" "meta without worktree reports cleanly"
pass "(i) missing meta / worktree degrade to unknown/none"

# --- (j) auto-compact launch env (Phase 2) ----------------------------------
# fm_context_autocompact_env emits the CLI-verified env prefix that keeps a claude
# session compacting around the ceiling, or nothing when disabled.
env_default=$(fm_context_autocompact_env)
assert_contains "$env_default" "CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000" "default window is the ceiling"
assert_contains "$env_default" "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=90" "default percent is 90"
case "$env_default" in *' ') pass "(j) autocompact env is space-terminated for prefixing" ;; *) fail "autocompact env must end with a space" ;; esac

cat > "$CONFIG/context-management" <<'EOF'
ceiling=180000
autocompact_pct=75
EOF
env_cfg=$(fm_context_autocompact_env)
assert_contains "$env_cfg" "CLAUDE_CODE_AUTO_COMPACT_WINDOW=180000" "config ceiling flows into the window"
assert_contains "$env_cfg" "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75" "config autocompact_pct is honored"
pass "(j2) config drives the auto-compact env"
rm -f "$CONFIG/context-management"

# disabled: pct=0, pct>100, and non-positive ceiling each emit nothing
[ -z "$(FM_CONTEXT_AUTOCOMPACT_PCT=0 fm_context_autocompact_env)" ] || fail "pct=0 must disable the env"
[ -z "$(FM_CONTEXT_AUTOCOMPACT_PCT=150 fm_context_autocompact_env)" ] || fail "pct>100 must disable the env"
[ -z "$(FM_CONTEXT_CEILING=0 fm_context_autocompact_env)" ] || fail "ceiling=0 must disable the env"
assert_contains "$(FM_CONTEXT_AUTOCOMPACT_PCT=50 fm_context_autocompact_env)" "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50" "env override sets the percent"
pass "(j3) auto-compact env disables cleanly and honors env overrides"

# --- (k) spawn wiring: claude launch carries the env, others do not ----------
SPAWN_SRC="$ROOT/bin/fm-spawn.sh"
assert_grep '__CTXENV__CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude' "$SPAWN_SRC" \
  "the claude launch template lost the __CTXENV__ auto-compact prefix"
# shellcheck disable=SC2016 # literal shell source, matched fixed-string, not expanded
assert_grep 'LAUNCH=${LAUNCH//__CTXENV__/$CTXENV}' "$SPAWN_SRC" \
  "fm-spawn lost the __CTXENV__ substitution"
# shellcheck disable=SC2016 # literal shell source, matched fixed-string, not expanded
assert_grep 'HARNESS" = claude ]; then CTXENV=$(fm_context_autocompact_env)' "$SPAWN_SRC" \
  "auto-compact env is not gated to the claude harness"
# No other harness template carries the placeholder.
if grep -nE '__CTXENV__' "$SPAWN_SRC" | grep -vE 'claude|CTXENV=|LAUNCH=' >/dev/null; then
  fail "a non-claude launch template carries the __CTXENV__ placeholder"
fi
pass "(k) spawn wires the auto-compact env into the claude launch only"

# --- usage error is exit 2 --------------------------------------------------
if "$GAUGE" --cwd >/dev/null 2>&1; then fail "--cwd with no dir must be a usage error"; fi
pass "usage error on --cwd with no argument"

pass "all fm-context-gauge cases passed"
