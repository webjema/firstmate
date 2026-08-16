#!/usr/bin/env bash
# Behavior tests for crew credential forwarding at spawn (fm-spawn.sh).
#
# A tmux window's shell inherits from the tmux SERVER, not from the client that
# created it, so firstmate's own credentials do not reach a crew's pane on their own.
# Forwarding them by TYPING `export TOKEN=<value>` into the pane worked but put the
# value in the pane's scrollback - which bin/fm-peek.sh reads straight into firstmate's
# context - and in the pane shell's history file. fm-spawn instead writes the values to
# a 0600 file under the task's temp root and types only its path.
#
# The load-bearing assertion in every case below is that the VALUE never appears in
# anything handed to tmux by any verb, nor in the spawn output firstmate reads.
#
# These drive the REAL fm-spawn.sh to completion against a fake tmux and a real git
# worktree, following the full-fake-spawn convention in tests/fm-spawn-env-seed.test.sh.
# Every fixture value here is a dummy string; no real credential is ever used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-crew-env)

# fm-spawn writes its task temp root at the fixed path /tmp/fm-<id>, outside TMP_ROOT,
# so this file owns removing it. It cannot be registered from make_spawn_case: that runs
# in a command substitution, and an array append inside a subshell is lost. Leftovers are
# not merely untidy here - a stale /tmp/fm-<id>/crew-env.sh makes the planted-symlink
# case below pass without ever planting the symlink. Own EXIT trap per the convention in
# tests/lib.sh, calling fm_test_cleanup so the registered dirs still go.
crew_env_cleanup() {
  rm -rf /tmp/fm-crewenv-*
  fm_test_cleanup
}
trap crew_env_cleanup EXIT

# Dummy values chosen to break naive quoting: a single quote, a space, and a `$`.
# shell_quote must survive all three intact through the file round-trip.
DUMMY_TOKEN="dummy-asana'tok en\$X"
DUMMY_GAC="/dummy/creds path.json"
# shell_quote rewrites an embedded single quote as '\'', so grepping the tmux log for
# DUMMY_TOKEN whole would MISS a typed-but-quoted secret - which is exactly the leak,
# since scrollback renders the quoted form perfectly readable. Assert on the fragment
# after the quote, which shell_quote passes through byte for byte.
DUMMY_TOKEN_TAIL="tok en\$X"

# A fake tmux that RECORDS the argv of EVERY invocation to $FM_FAKE_TMUXLOG. That log
# is how the tests prove the value never travelled to the pane.
#
# Logging every verb rather than just send-keys is deliberate: `tmux new-window -e
# VAR=value` is the rejected alternative that puts the value in the tmux client's argv,
# and a fake that swallowed new-window would let exactly that regression pass every
# assertion here. The log has to cover the tmux SURFACE, not one verb of it.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUXLOG:-/dev/null}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys|has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

# Build one spawn case: a firstmate home, a project clone, a real worktree standing in
# for the treehouse slot, and a fake bin dir. Echoes a '|'-joined record because a bash
# function cannot return several values. Clears any /tmp/fm-<id> a killed earlier run
# left behind, so no case can pass against stale state.
make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/alpha"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="crewenv-$name-x1"
  rm -rf "/tmp/fm-$id"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

# Runs the real fm-spawn.sh with ONLY the credential vars this case declares. `env -u`
# each forwarded var first, so the developer's own real environment cannot leak into a
# fixture and make an assertion pass or fail for the wrong reason.
run_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  env -u GOOGLE_APPLICATION_CREDENTIALS -u GOOGLE_VERTEX_PROJECT \
      -u GOOGLE_VERTEX_LOCATION -u ASANA_ACCESS_TOKEN -u ANTHROPIC_API_KEY \
      -u OPENAI_API_KEY -u GEMINI_API_KEY -u OPENROUTER_API_KEY \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_TMUXLOG="$FM_FAKE_TMUXLOG" \
    PATH="$fakebin:$PATH" \
    "$@" \
    "$SPAWN" "$id" "$proj" claude 2>&1
}

# The headline case: the crew gets the credentials, and the value reaches the pane only
# as a path to read.
test_value_never_travels_through_the_pane() {
  local rec case_dir home proj wt fakebin id out envfile mode sourced
  rec=$(make_spawn_case leak)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  FM_FAKE_TMUXLOG="$case_dir/tmuxlog"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    ASANA_ACCESS_TOKEN="$DUMMY_TOKEN" GOOGLE_APPLICATION_CREDENTIALS="$DUMMY_GAC")
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report success"

  envfile="/tmp/fm-$id/crew-env.sh"
  assert_present "$envfile" "spawn did not write the crew env file"
  mode=$(stat -c '%a' "$envfile" 2>/dev/null || stat -f '%Lp' "$envfile")
  [ "$mode" = 600 ] || fail "crew env file mode is $mode, expected 600"

  # The defect this change exists to close, asserted on both readable surfaces and at
  # the channel itself: nothing that assigns a credential may be typed at all.
  assert_no_grep 'export ASANA_ACCESS_TOKEN' "$FM_FAKE_TMUXLOG" \
    "a credential assignment was handed to tmux"
  assert_no_grep "$DUMMY_TOKEN_TAIL" "$FM_FAKE_TMUXLOG" \
    "the credential VALUE was handed to tmux"
  assert_no_grep "$DUMMY_GAC" "$FM_FAKE_TMUXLOG" \
    "the credential VALUE was handed to tmux"
  assert_not_contains "$out" "$DUMMY_TOKEN_TAIL" \
    "the credential VALUE appeared in the spawn output firstmate reads"

  # ... and the crew still actually gets it. Source the file the way the pane does and
  # read the values back, which also proves shell_quote survived the round-trip.
  assert_grep ". '$envfile'" "$FM_FAKE_TMUXLOG" "spawn never told the pane to source the env file"
  sourced=$(env -u ASANA_ACCESS_TOKEN -u GOOGLE_APPLICATION_CREDENTIALS \
    bash -c ". '$envfile'; printf '%s|%s' \"\$ASANA_ACCESS_TOKEN\" \"\$GOOGLE_APPLICATION_CREDENTIALS\"")
  [ "$sourced" = "$DUMMY_TOKEN|$DUMMY_GAC" ] \
    || fail "sourcing the crew env file did not restore the values intact (got: $sourced)"

  # Names in the report line are useful and safe; values are not.
  assert_contains "$out" "crew-env: forwarded=GOOGLE_APPLICATION_CREDENTIALS,ASANA_ACCESS_TOKEN" \
    "spawn did not report which vars it forwarded, by name"
  pass "spawn forwards credentials via a 0600 file and never types the value into the pane"
}

# An unset var must be absent from the file, not exported as empty: an empty
# ANTHROPIC_API_KEY in the crew's env is worse than none, because it overrides whatever
# the harness would otherwise resolve.
test_unset_vars_are_omitted() {
  local rec case_dir home proj wt fakebin id out envfile
  rec=$(make_spawn_case partial)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  FM_FAKE_TMUXLOG="$case_dir/tmuxlog"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" ASANA_ACCESS_TOKEN="$DUMMY_TOKEN")
  envfile="/tmp/fm-$id/crew-env.sh"
  assert_grep 'export ASANA_ACCESS_TOKEN=' "$envfile" "the set var was not written"
  assert_no_grep 'ANTHROPIC_API_KEY' "$envfile" "an unset var was exported as empty"
  assert_no_grep 'OPENAI_API_KEY' "$envfile" "an unset var was exported as empty"
  assert_contains "$out" "crew-env: forwarded=ASANA_ACCESS_TOKEN" \
    "spawn reported vars it did not forward"
  pass "spawn omits unset credential vars rather than exporting them empty"
}

# No credentials in firstmate's own env is the normal case on a fresh box: leave no
# file behind, tell the pane nothing, and say so in one line.
test_no_credentials_leaves_no_file() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case none)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  FM_FAKE_TMUXLOG="$case_dir/tmuxlog"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "spawn with no credentials in the environment"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report success"
  assert_contains "$out" "crew-env: forwarded=0" "spawn did not report the zero count line"
  assert_absent "/tmp/fm-$id/crew-env.sh" "spawn left an empty crew env file behind"
  assert_no_grep 'crew-env.sh' "$FM_FAKE_TMUXLOG" \
    "spawn told the pane to source a file it did not write"
  pass "spawn with no credentials writes no file and reports a zero count"
}

# The env file must live outside every worktree, or the next crew commits a credential.
test_env_file_is_outside_the_worktree() {
  local rec case_dir home proj wt fakebin id
  rec=$(make_spawn_case isolation)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  FM_FAKE_TMUXLOG="$case_dir/tmuxlog"
  run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" ASANA_ACCESS_TOKEN="$DUMMY_TOKEN" >/dev/null
  assert_present "/tmp/fm-$id/crew-env.sh" "precondition: spawn should have written the env file"
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || fail "spawn wrote something into the crew's checkout: $(git -C "$wt" status --porcelain)"
  assert_no_grep "$DUMMY_TOKEN_TAIL" "$FM_FAKE_TMUXLOG" "the credential VALUE was handed to tmux"
  pass "the crew env file lives outside the worktree, so git never sees it"
}

# The env file's path is predictable (/tmp/fm-<id>/crew-env.sh from a short kebab id)
# and `mkdir -p` succeeds on a directory somebody else already made, so a plain `>`
# would follow a planted symlink and write the credential wherever it points. Writing
# through the link is the one unrecoverable failure here, so it is tested rather than
# argued.
test_planted_symlink_is_not_written_through() {
  local rec case_dir home proj wt fakebin id decoy
  rec=$(make_spawn_case symlink)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  FM_FAKE_TMUXLOG="$case_dir/tmuxlog"
  decoy="$case_dir/decoy.txt"
  printf 'untouched\n' > "$decoy"
  mkdir -p "/tmp/fm-$id"
  ln -s "$decoy" "/tmp/fm-$id/crew-env.sh"
  run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" ASANA_ACCESS_TOKEN="$DUMMY_TOKEN" >/dev/null
  assert_no_grep "$DUMMY_TOKEN_TAIL" "$decoy" "spawn wrote the credential through a planted symlink"
  assert_grep 'untouched' "$decoy" "spawn truncated the symlink's target"
  [ ! -L "/tmp/fm-$id/crew-env.sh" ] || fail "the crew env file is still a symlink, not a real file"
  pass "spawn replaces a planted symlink instead of writing the credential through it"
}

test_value_never_travels_through_the_pane
test_unset_vars_are_omitted
test_no_credentials_leaves_no_file
test_env_file_is_outside_the_worktree
test_planted_symlink_is_not_written_through
