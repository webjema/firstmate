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
#   (g) the gate's own budget stays under the hook timeout that would cancel it
#   (h) a check that outruns the budget REFUSES the push, by name
#   (i) a check that simply fails still blocks
#
# (g) through (i) exist because a cancelled hook is worse than an absent one:
# Claude Code runs the tool anyway when a hook outruns its timeout, so an
# overrun that is not refused first is read as consent. (h) drives the emitted
# hook end to end, with the budget shrunk to keep the test quick.
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

# (g) The no-fail-open invariant, asserted on the two numbers themselves. ------
test_gate_budget_stays_under_the_hook_timeout() {
  local dir budget timeout
  dir=$(make_project budget '{ "test": "jest", "typecheck": "tsc --noEmit" }')
  "$HOOKS" "$dir" >/dev/null

  budget=$(sed -n 's/^GATE_BUDGET=\([0-9]\{1,\}\)$/\1/p' "$dir/.claude/hooks/fm-quality-pre-push.sh")
  timeout=$(awk '/fm-quality-pre-push\.sh/ { seen = 1 }
                 seen && /"timeout"/ { gsub(/[^0-9]/, ""); print; exit }' "$dir/.claude/settings.json")

  [ -n "$budget" ] || fail "budget: the emitted gate sets itself no deadline"
  [ -n "$timeout" ] || fail "budget: settings.json gives the gate no timeout"
  [ "$budget" -lt "$timeout" ] \
    || fail "budget: the gate's ${budget}s deadline must stay under the ${timeout}s hook timeout, or it is cancelled mid-verdict and the push proceeds"
  pass "the gate's own deadline stays under the hook timeout that would cancel it"
}

# A committed git project whose `npm run <script>` is a shim under fakebin/, so
# the emitted hook can be driven for real without a node toolchain. $2 is the
# body of `npm run typecheck`, $3 the body of `npm run test`.
make_gate_project() {
  local name=$1 typecheck=$2 test=$3 dir
  dir=$(make_project "$name" '{ "test": "jest", "typecheck": "tsc --noEmit" }')
  "$HOOKS" "$dir" >/dev/null

  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/npm" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = run ] || exit 0
case "\$2" in
  typecheck) $typecheck ;;
  test) $test ;;
esac
EOF
  chmod +x "$dir/fakebin/npm"

  # Shrink the budget so an overrun is measured in seconds, not minutes. The
  # gate's logic is the shipped one; only the number is test-sized.
  sed -i.bak 's/^GATE_BUDGET=[0-9]\{1,\}$/GATE_BUDGET=2/' "$dir/.claude/hooks/fm-quality-pre-push.sh"
  rm -f "$dir/.claude/hooks/fm-quality-pre-push.sh.bak"

  # The gate refuses a dirty tree before it reaches any check.
  git -C "$dir" init -q
  git -C "$dir" add -A
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fixture
  printf '%s\n' "$dir"
}

run_gate() {
  local dir=$1
  ( cd "$dir" \
      && PATH="$dir/fakebin:$PATH" CLAUDE_PROJECT_DIR="$dir" \
         ./.claude/hooks/fm-quality-pre-push.sh <<< '{"tool_input":{"command":"git push -u origin main"}}' 2>&1 )
}

# (h) The defect this whole file exists to keep fixed. ------------------------
test_overrunning_check_refuses_the_push() {
  local dir out code=0
  dir=$(make_gate_project overrun 'exit 0' 'sleep 60')
  out=$(run_gate "$dir") || code=$?

  expect_code 2 "$code" "overrun: an unfinished check must block the push, not let it through"
  assert_contains "$out" 'BLOCKED' "overrun: refuses out loud"
  assert_contains "$out" 'tests' "overrun: names which check ran out of budget"
  assert_contains "$out" 'by hand' "overrun: says how to get past it"
  pass "a check that outruns the gate's budget refuses the push instead of passing it"
}

# (i) The refusal above must not have cost the ordinary verdict. --------------
test_failing_check_still_blocks() {
  local dir out code=0
  dir=$(make_gate_project failing 'exit 0' 'echo "1 test failed"; exit 1')
  out=$(run_gate "$dir") || code=$?

  expect_code 2 "$code" "failing: a failed check must block the push"
  assert_contains "$out" 'BLOCKED: tests failed' "failing: names the check that failed"
  assert_contains "$out" '1 test failed' "failing: the check's own output reaches the agent"

  dir=$(make_gate_project passing 'exit 0' 'exit 0')
  code=0
  out=$(run_gate "$dir") || code=$?
  expect_code 0 "$code" "passing: checks that pass inside the budget let the push through"
  pass "a check that fails still blocks, and one that passes still lets the push through"
}

test_never_clobbers_existing_hooks
test_installs_bundle_when_absent
test_pre_push_gate_uses_detected_scripts
test_empty_gate_is_announced_loudly
test_check_never_writes
test_rerun_is_idempotent
test_gate_budget_stays_under_the_hook_timeout
test_overrunning_check_refuses_the_push
test_failing_check_still_blocks
