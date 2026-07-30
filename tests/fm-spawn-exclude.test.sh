#!/usr/bin/env bash
# Behavior test for fm-spawn.sh keeping the crew's own scratch out of git's view.
#
# bin/fm-brief.sh tells every crew to keep a running plan at .fm/progress.md and
# never to commit it. Without an exclude, a crew that follows the brief leaves an
# untracked file behind, bin/fm-teardown.sh reads untracked files as unlanded
# work, and the release is REFUSED - a false alarm on a task whose work is fully
# merged, cleared only by a forced teardown. So the spawn excludes .fm/ the same
# way it excludes its own worktree-resident hook files.
#
# Driven through a real fm-spawn.sh against a real git worktree, with tmux and
# treehouse stubbed, because the assertion that matters is what `git status` in
# that worktree reports - not that a line was written somewhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-exclude)

test_scratch_dir_is_excluded() {
  local case_dir home proj wt fakebin id out status
  case_dir="$TMP_ROOT/scratch"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="scratch-excl-x1"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh claude
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" claude 2>&1)
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  # The crew now does exactly what its brief tells it to.
  mkdir -p "$wt/.fm"
  printf 'plan\n' > "$wt/.fm/progress.md"
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || fail "a crew that kept .fm/progress.md as briefed left the worktree dirty; teardown will refuse to release it"
  pass "the crew's scratch dir is excluded, so following the brief cannot block teardown"
}

test_scratch_dir_is_excluded
