#!/usr/bin/env bash
# Tests for harness-aware supervision instruction rendering.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-instructions)
RENDER="$ROOT/bin/fm-supervision-instructions.sh"

test_selected_harness_block_only() {
  local out
  out=$("$RENDER" --harness codex)
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: codex" "codex heading missing"
  assert_contains "$out" "Mode: Codex foreground checkpoint." "codex snippet missing"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex checkpoint helper missing"
  assert_not_contains "$out" "Mode: Claude background-notify supervision." "renderer printed the claude snippet too"
  assert_not_contains "$out" "Mode: Pi extension background wake." "renderer printed the pi snippet too"
  pass "renderer prints exactly the selected harness block"
}

test_unknown_fallback() {
  local out
  out=$("$RENDER" --harness not-real)
  assert_contains "$out" "primary harness: unknown" "unknown heading missing"
  assert_contains "$out" "Mode: Unknown harness fallback." "unknown fallback snippet missing"
  pass "renderer falls back to unknown.md for unverified harness names"
}

test_conditional_stanzas() {
  local home config out
  home="$TMP_ROOT/conditional-home"
  config="$TMP_ROOT/conditional-config"
  mkdir -p "$home/state" "$home/config" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex --read-only 1 --afk 1)
  assert_contains "$out" "- Lock: read-only" "read-only stanza missing"
  assert_contains "$out" "- Away mode: active" "afk stanza missing"
  assert_contains "$out" 'Mode: Codex foreground checkpoint.' "codex snippet missing"
  assert_not_contains "$out" "X mode" "renderer kept an X-mode stanza after the subsystem was removed"
  pass "renderer includes read-only and afk current-state stanzas"
}

test_repair_lines() {
  local home out
  home="$TMP_ROOT/repair-home"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --repair-line)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "codex repair line did not use checkpoint helper and env override"

  out=$(FM_HOME="$home" "$RENDER" --harness claude --queue-pending 1 --repair-line)
  assert_contains "$out" "After draining queued wakes" "queue-pending prefix missing"
  assert_contains "$out" "Claude Code background task" "claude repair line missing background-task mechanism"

  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --repair-line)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "codex repair line lost the checkpoint helper"

  out=$(FM_HOME="$home" "$RENDER" --harness opencode --read-only 1 --repair-line)
  assert_contains "$out" "session holding the fleet lock" "read-only repair line missing"

  out=$(FM_HOME="$home" "$RENDER" --harness pi --repair-line)
  assert_contains "$out" "Pi tool fm_watch_arm_pi" "pi repair line does not direct the model to the extension-owned tool"
  assert_not_contains "$out" "extension command /fm-watch-arm-pi" "pi repair line still directs the model to the human slash command"
  pass "renderer repair-line mode is harness-aware and honors conditional state"
}

test_grok_is_background_notify() {
  local out
  out=$("$RENDER" --harness grok)
  assert_contains "$out" "Mode: Grok background-notify supervision." "grok snippet missing background-notify mode"
  assert_contains "$out" "background: true" "grok snippet missing tracked background tool instruction"
  assert_contains "$out" "synthetic_reason: task_completed" "grok snippet missing auto-wake synthetic prompt detail"
  assert_contains "$out" "bin/fm-watch-arm.sh" "grok snippet missing watcher arm"
  assert_not_contains "$out" "__FM_" "renderer leaked an unsubstituted path placeholder"
  assert_not_contains "$out" "foreground checkpoint" "grok snippet must not be Codex-style foreground checkpoint"
  out=$("$RENDER" --harness grok --repair-line)
  assert_contains "$out" "Grok tracked background task" "grok repair line is not background-notify shaped"
  pass "grok supervision is Claude-shaped background notify with passive Stop-hook backstop"
}

test_grok_command_sources_effective_config() {
  local home config out
  home="$TMP_ROOT/grok-home"
  config="$TMP_ROOT/grok-config"
  mkdir -p "$home/state" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok)
  assert_contains "$out" "exec bin/fm-watch-arm.sh" "grok arm command lost its background arm invocation"
  pass "grok renders its background arm command"
}

test_pi_snippet_uses_effective_extension_path() {
  local home out turnend watch
  home="$TMP_ROOT/pi-home"
  turnend="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  watch="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" "$RENDER" --harness pi)
  assert_contains "$out" "-e $turnend -e $watch" "pi snippet did not render both effective extension launch paths"
  assert_contains "$out" "The turn-end guard extension lives at \`$turnend\`" "pi snippet did not render the turn-end guard extension path"
  assert_contains "$out" "The watcher extension lives at \`$watch\`" "pi snippet did not render the watcher extension path"
  assert_not_contains "$out" "__FM_PI_EXT__" "renderer leaked the Pi extension path placeholder"
  assert_not_contains "$out" "__FM_PI_TURNEND_EXT__" "renderer leaked the Pi turn-end extension path placeholder"
  assert_not_contains "$out" "state/fm-primary-pi-watch.ts" "pi snippet kept the old generated state-relative extension path"
  pass "pi supervision snippet renders the effective extension path"
}

test_selected_harness_block_only
test_unknown_fallback
test_conditional_stanzas
test_repair_lines
test_grok_is_background_notify
test_grok_command_sources_effective_config
test_pi_snippet_uses_effective_extension_path
