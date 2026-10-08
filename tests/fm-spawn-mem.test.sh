#!/usr/bin/env bash
# Behavior tests for memory admission at spawn (fm-spawn.sh + fm-mem-lib.sh).
#
# A spawn below the memory reserve waits, then launches when memory frees up or the
# wait bound passes - it never refuses. A crew on a verified harness launches inside
# a user systemd scope with MemoryHigh when the box can make one.
#
# These drive the REAL fm-spawn.sh to completion against a fake tmux, a fake meminfo
# and a real git worktree, following tests/fm-spawn-crew-env.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-mem)

SHORT=1200000
AMPLE=9000000

meminfo() {  # <available-kb>
  printf 'MemTotal: 16000000 kB\nMemAvailable: %s kB\n' "$1" > "$CASE/meminfo"
}

make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TMUXLOG:-/dev/null}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
[ "${1:-}" = display-message ] && printf 'firstmate\n'
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

# make_case <name> <id>...: one home with a brief per id, a project, a worktree.
# Pins config/crew-harness so a spawn with no explicit harness (the batch form)
# never falls through to host detection, which is `unknown` on a CI runner.
# Sets CASE, HOME_DIR, PROJ, WT, FAKEBIN.
make_case() {
  local id
  CASE="$TMP_ROOT/$1"; shift
  HOME_DIR="$CASE/home"
  PROJ="$CASE/alpha"
  WT="$CASE/wt"
  FAKEBIN=$(make_fakebin "$CASE/fake")
  mkdir -p "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  for id in "$@"; do
    mkdir -p "$HOME_DIR/data/$id"
    printf 'brief\n' > "$HOME_DIR/data/$id/brief.md"
  done
  fm_git_worktree "$PROJ" "$WT" "fm/$1"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  touch "$HOME_DIR/state/.last-watcher-beat"
  : > "$CASE/tmuxlog"
}

run_spawn() {  # [VAR=value...] -- <spawn args...>
  local -a vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done
  shift
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" TMUX="fake,1,0" \
    FM_FAKE_TMUXLOG="$CASE/tmuxlog" FM_MEMINFO="$CASE/meminfo" \
    FM_MEM_RESERVE_GB=4 FM_SPAWN_MEM_POLL=1 FM_CREW_MEMORY_HIGH=off \
    PATH="$FAKEBIN:$PATH" \
    ${vars[@]+"${vars[@]}"} \
    "$SPAWN" "$@" 2>&1
}

test_waits_then_launches_when_memory_frees() {
  local out
  make_case frees memfree-x1
  meminfo "$SHORT"
  ( sleep 2; meminfo "$AMPLE" ) >/dev/null 2>&1 &
  out=$(run_spawn FM_SPAWN_MEM_WAIT_MAX=60 -- memfree-x1 "$PROJ" claude)
  wait
  assert_contains "$out" "mem-wait: memfree-x1 waiting for memory: 1.1 GB available, below the 4 GB reserve" "spawn did not report the wait"
  assert_contains "$out" "mem-wait: memfree-x1 memory freed after" "spawn did not report memory freeing"
  assert_contains "$out" "spawned memfree-x1 harness=claude" "spawn did not launch after memory freed"
  pass "a spawn below the reserve waits, then launches when memory frees"
}

test_launches_anyway_after_the_bound() {
  local out
  make_case bound membound-x1
  meminfo "$SHORT"
  out=$(run_spawn FM_SPAWN_MEM_WAIT_MAX=02 FM_SPAWN_MEM_POLL=01 -- membound-x1 "$PROJ" claude)
  assert_contains "$out" "mem-wait: membound-x1 still short after 2s" "spawn did not say it gave up waiting"
  assert_contains "$out" "launching anyway" "spawn did not say it launched anyway"
  assert_contains "$out" "spawned membound-x1 harness=claude" "spawn refused instead of launching"
  pass "a spawn still short after the wait bound launches anyway and says so"
}

test_ample_memory_does_not_wait() {
  local out
  make_case ample memample-x1
  meminfo "$AMPLE"
  out=$(run_spawn -- memample-x1 "$PROJ" claude)
  assert_not_contains "$out" "mem-wait:" "a spawn with ample memory must not wait"
  assert_contains "$out" "spawned memample-x1" "spawn did not launch"
  pass "a spawn with memory above the reserve launches without waiting"
}

test_batch_checks_before_each_launch() {
  local out
  make_case batch membatch-a1 membatch-b1
  meminfo "$SHORT"
  out=$(run_spawn FM_SPAWN_MEM_WAIT_MAX=1 -- "membatch-a1=$PROJ" "membatch-b1=$PROJ")
  assert_contains "$out" "mem-wait: membatch-a1 waiting" "the first pair did not check memory"
  assert_contains "$out" "mem-wait: membatch-b1 waiting" "the second pair did not check memory"
  assert_contains "$out" "spawned membatch-b1" "the batch did not launch its second pair"
  pass "a batch spawn checks memory before each launch"
}

# A fake systemd-run that records its argv and exits with $FM_FAKE_SDRUN_RC.
fake_systemd_run() {
  cat > "$FAKEBIN/systemd-run" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE/sdrun.log"
exit \${FM_FAKE_SDRUN_RC:-0}
SH
  chmod +x "$FAKEBIN/systemd-run"
}

test_crew_launches_in_a_memory_high_scope() {
  local out
  make_case scope memscope-x1
  meminfo "$AMPLE"
  fake_systemd_run
  out=$(run_spawn FM_CREW_MEMORY_HIGH=6G XDG_RUNTIME_DIR=/run/user/4242 DBUS_SESSION_BUS_ADDRESS= -- memscope-x1 "$PROJ" claude)
  assert_contains "$out" "spawned memscope-x1" "spawn did not launch"
  assert_grep "systemd-run --user --scope --quiet -p MemoryHigh=6G env CLAUDE_CODE" "$CASE/tmuxlog" \
    "the crew launch was not wrapped in a MemoryHigh scope"
  assert_grep "XDG_RUNTIME_DIR=/run/user/4242 systemd-run" "$CASE/tmuxlog" \
    "the pane launch must reach the user manager the probe reached"
  pass "a crew launches inside a user scope with MemoryHigh"
}

test_no_scope_when_the_box_cannot_make_one() {
  local out
  make_case noscope memnoscope-x1
  meminfo "$AMPLE"
  fake_systemd_run
  out=$(run_spawn FM_CREW_MEMORY_HIGH=6G FM_FAKE_SDRUN_RC=1 -- memnoscope-x1 "$PROJ" claude)
  assert_contains "$out" "spawned memnoscope-x1" "spawn did not launch"
  assert_no_grep "systemd-run" "$CASE/tmuxlog" "a box that cannot make a scope must launch the crew bare"
  assert_grep "claude --dangerously-skip-permissions" "$CASE/tmuxlog" "the crew was not launched"
  pass "a box with no usable user systemd launches the crew without a scope"
}

test_waits_then_launches_when_memory_frees
test_launches_anyway_after_the_bound
test_ample_memory_does_not_wait
test_batch_checks_before_each_launch
test_crew_launches_in_a_memory_high_scope
test_no_scope_when_the_box_cannot_make_one
