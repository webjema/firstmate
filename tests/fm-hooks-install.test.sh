#!/usr/bin/env bash
# Tests for bin/fm-hooks-install.sh: the mechanical quality floor a crewmate
# commits into a project.
#
# The load-bearing behavior is NEVER CLOBBER. A project that hand-tuned its hooks
# has knowledge in them that this generic installer does not; overwriting that
# would be a quality regression dressed up as an install. Everything else here is
# secondary to that.
#
# Matrix:
#   (a) project with its own hooks -> untouched, reported
#   (b) project with no hooks -> starter bundle installed
#   (c) the pre-push gate is wired from the project's OWN detected npm scripts
#   (d) no detectable test/typecheck -> installs, but says loudly that the gate is empty
#   (e) --check never writes
#   (f) re-running is idempotent
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOKS="$ROOT/bin/fm-hooks-install.sh"
TMP_ROOT=$(fm_test_tmproot fm-hooks-install-tests)

make_project() {
  local name=$1 scripts=${2:-} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  if [ -n "$scripts" ]; then
    cat > "$dir/package.json" <<EOF
{ "name": "$name", "scripts": $scripts }
EOF
  fi
  printf '%s\n' "$dir"
}

# (a) The whole point. --------------------------------------------------------
test_never_clobbers_existing_hooks() {
  local dir out before after
  dir=$(make_project own_hooks '{ "test": "jest" }')
  mkdir -p "$dir/.claude"
  cat > "$dir/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "./hand-tuned.sh" } ] }
    ]
  }
}
EOF
  before=$(cat "$dir/.claude/settings.json")
  out=$("$HOOKS" "$dir")
  after=$(cat "$dir/.claude/settings.json")

  [ "$before" = "$after" ] || fail "existing hooks: settings.json must be byte-identical after the run"
  assert_contains "$out" 'left untouched' "existing hooks: says it left them alone"
  assert_absent "$dir/.claude/hooks/fm-quality-pre-push.sh" "existing hooks: installs no starter hook scripts"
  pass "a project with its own hooks is never clobbered"
}

# (b) ------------------------------------------------------------------------
test_installs_bundle_when_absent() {
  local dir out
  dir=$(make_project fresh '{ "test": "jest", "typecheck": "tsc --noEmit" }')
  out=$("$HOOKS" "$dir")

  assert_contains "$out" 'installed' "fresh: reports the install"
  assert_present "$dir/.claude/settings.json" "fresh: writes settings.json"
  assert_present "$dir/.claude/hooks/fm-quality-secret-scan.sh" "fresh: installs the secret scan"
  assert_present "$dir/.claude/hooks/fm-quality-pre-push.sh" "fresh: installs the pre-push gate"
  [ -x "$dir/.claude/hooks/fm-quality-pre-push.sh" ] || fail "fresh: hook scripts must be executable"
  assert_grep 'fm-quality' "$dir/.claude/settings.json" "fresh: settings carries the marker"
  pass "a project with no hooks gets the starter bundle"
}

# (c) The gate must run the PROJECT's checks, not invented ones. --------------
test_pre_push_gate_uses_detected_scripts() {
  local dir
  dir=$(make_project detected '{ "test": "vitest run", "typecheck": "tsc -b" }')
  "$HOOKS" "$dir" >/dev/null

  assert_grep 'npm run test' "$dir/.claude/hooks/fm-quality-pre-push.sh" "detected: wires the project's test script"
  assert_grep 'npm run typecheck' "$dir/.claude/hooks/fm-quality-pre-push.sh" "detected: wires the project's typecheck script"
  assert_grep 'git push' "$dir/.claude/hooks/fm-quality-pre-push.sh" "detected: only fires on push"
  pass "the pre-push gate is wired from the project's own detected scripts"
}

# (d) An empty gate is worse than no gate if it pretends to be one. -----------
test_empty_gate_is_announced_loudly() {
  local dir out
  dir=$(make_project no_scripts '{ "build": "make" }')
  out=$("$HOOKS" "$dir")

  assert_contains "$out" 'WARNING' "no scripts: warns"
  assert_contains "$out" 'empty' "no scripts: says the gate is empty"
  assert_grep 'an empty gate is not a gate' "$dir/.claude/hooks/fm-quality-pre-push.sh" "no scripts: leaves the warning in the hook itself"
  pass "a project with no detectable checks is told its gate is empty"
}

# (e) ------------------------------------------------------------------------
test_check_never_writes() {
  local dir out
  dir=$(make_project checkonly '{ "test": "jest" }')
  out=$("$HOOKS" --check "$dir")

  assert_contains "$out" 'HOOKS_MISSING' "check: reports the gap"
  assert_absent "$dir/.claude/settings.json" "check: writes nothing"
  pass "--check reports without writing"
}

# (f) ------------------------------------------------------------------------
test_rerun_is_idempotent() {
  local dir out before after
  dir=$(make_project rerun '{ "test": "jest" }')
  "$HOOKS" "$dir" >/dev/null
  before=$(cat "$dir/.claude/settings.json")
  out=$("$HOOKS" "$dir")
  after=$(cat "$dir/.claude/settings.json")

  [ "$before" = "$after" ] || fail "rerun: must not rewrite an already-installed bundle"
  assert_contains "$out" 'already installed' "rerun: says it is already installed"
  pass "re-running is idempotent"
}

test_never_clobbers_existing_hooks
test_installs_bundle_when_absent
test_pre_push_gate_uses_detected_scripts
test_empty_gate_is_announced_loudly
test_check_never_writes
test_rerun_is_idempotent
