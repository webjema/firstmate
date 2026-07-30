#!/usr/bin/env bash
# Behavior tests for per-project local env seeding at spawn (fm-spawn.sh).
#
# A treehouse pool slot keeps whatever gitignored files it was warmed with
# forever (bin/fm-pool-warm.sh resets with `git clean -fd`, no -x), so slots drift
# and a crew in a bare slot reports a credential absent that the box already holds.
# fm-spawn closes that by copying config/project-env/<project>/ into the crew's
# checkout at spawn.
#
# These drive the REAL fm-spawn.sh to completion against a fake tmux and a real git
# worktree, following the full-fake-spawn convention in tests/fm-grok-harness.test.sh.
# Every fixture value here is a dummy string; no real credential is ever used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-env-seed)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
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
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

# Build one spawn case: a firstmate home, a project clone named <project>, a real
# worktree of it standing in for the treehouse slot, and a fake bin dir. Echoes a
# '|'-joined record because a bash function cannot return several values.
make_spawn_case() {
  local name=$1 project=${2:-alpha} case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/$project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="seed-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" claude 2>&1
}

# Write the canonical env tree for <project> into <home>/config/project-env, with
# a root file and a nested one, mirroring optiroq's real shape. Dummy values only.
seed_canonical_dir() {
  local home=$1 project=$2 src="$1/config/project-env/$2"
  mkdir -p "$src/src/portal-ui"
  printf 'E2E_BUYER_B_TOKEN=dummy-buyer-b\n' > "$src/.env.e2e"
  printf 'PORTAL_UI_TOKEN=dummy-portal\n' > "$src/src/portal-ui/.env.local"
  chmod 600 "$src/.env.e2e" "$src/src/portal-ui/.env.local"
  printf '%s\n' "$src"
}

# The headline case: a slot that lacks the key gets the complete tree, at mode 600,
# and git never sees the seeded files.
test_seeds_complete_tree_into_bare_slot() {
  local rec case_dir home proj wt fakebin id out mode
  rec=$(make_spawn_case bare optiroq)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  seed_canonical_dir "$home" optiroq >/dev/null
  # Precondition: the slot is bare, exactly like slots 2-4 of the real pool.
  assert_absent "$wt/.env.e2e" "precondition: worktree should start without .env.e2e"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report success"
  assert_contains "$out" "env-seed: project=optiroq seeded=2 unchanged=0 conflict=0" \
    "spawn did not report the seeded count"
  assert_grep 'E2E_BUYER_B_TOKEN' "$wt/.env.e2e" "root env file was not seeded"
  assert_grep 'PORTAL_UI_TOKEN' "$wt/src/portal-ui/.env.local" "nested env file was not seeded"
  mode=$(stat -c '%a' "$wt/.env.e2e" 2>/dev/null || stat -f '%Lp' "$wt/.env.e2e")
  [ "$mode" = 600 ] || fail "seeded env file mode is $mode, expected 600"
  # The unrecoverable failure this feature must never cause: a credential visible to
  # git. fm-spawn excludes each seeded path, so the fixture project's own (absent)
  # ignore rules cannot betray it.
  assert_not_contains "$(git -C "$wt" status --porcelain)" '.env.e2e' \
    "seeded env file is visible to git in the crew's checkout"
  assert_not_contains "$(git -C "$wt" status --porcelain)" '.env.local' \
    "seeded nested env file is visible to git in the crew's checkout"
  pass "spawn seeds the complete canonical env tree into a bare slot, mode 600, hidden from git"
}

# No canonical dir is the normal case for most projects: no error, no extra output
# beyond the count line, nothing written.
test_no_canonical_dir_is_a_no_op() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case nodir beta)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "spawn for a project with no canonical env dir"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report success"
  assert_contains "$out" "env-seed: project=beta seeded=0 unchanged=0 conflict=0" \
    "spawn did not report the zero count line"
  assert_not_contains "$out" "warn: env-seed" "no-canonical-dir spawn emitted a warning"
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || fail "no-canonical-dir spawn wrote something into the worktree"
  pass "spawn with no canonical env dir is a silent no-op with a zero count line"
}

# The no-clobber rule: an existing DIFFERENT file is the crew's own local edit.
# Warn, name the path, and leave the bytes alone. An existing IDENTICAL file is
# simply already correct and counts as unchanged.
test_existing_file_is_never_clobbered() {
  local rec case_dir home proj wt fakebin id out
  rec=$(make_spawn_case existing optiroq)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  seed_canonical_dir "$home" optiroq >/dev/null
  # One file the crew has edited, one already identical to the canonical copy.
  printf 'E2E_BUYER_B_TOKEN=crew-local-edit\n' > "$wt/.env.e2e"
  mkdir -p "$wt/src/portal-ui"
  printf 'PORTAL_UI_TOKEN=dummy-portal\n' > "$wt/src/portal-ui/.env.local"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  assert_contains "$out" "env-seed: project=optiroq seeded=0 unchanged=1 conflict=1" \
    "spawn did not classify the existing files as unchanged/conflict"
  assert_contains "$out" "warn: env-seed: .env.e2e" "the differing path was not named in a warn line"
  assert_grep 'crew-local-edit' "$wt/.env.e2e" "the crew's own env file was clobbered"
  assert_no_grep 'dummy-buyer-b' "$wt/.env.e2e" "the canonical copy overwrote the crew's env file"
  pass "spawn leaves an existing-but-different env file alone and warns, naming the path"
}

# A path the project TRACKS is never a local env file, and seeding one would stage a
# credential for commit. Refuse, warn, leave the tracked content intact.
test_tracked_path_is_refused() {
  local rec case_dir home proj wt fakebin id out
  rec=$(make_spawn_case tracked gamma)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$home/config/project-env/gamma"
  printf 'SEEDED=dummy\n' > "$home/config/project-env/gamma/.env.e2e"
  # Track the path in the project, then remove it from the worktree so the
  # exists-check passes and only the tracked-check can stop the seed.
  printf 'TRACKED=placeholder\n' > "$wt/.env.e2e"
  git -C "$wt" add .env.e2e
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -qm 'track env'
  rm "$wt/.env.e2e"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  assert_contains "$out" "env-seed: project=gamma seeded=0 unchanged=0 conflict=1" \
    "spawn did not classify the tracked path as a conflict"
  assert_contains "$out" "warn: env-seed: .env.e2e is tracked by the project" \
    "the tracked path was not refused with a warn line"
  assert_absent "$wt/.env.e2e" "spawn seeded a credential over a tracked path"
  pass "spawn refuses to seed over a path the project tracks"
}

test_seeds_complete_tree_into_bare_slot
test_no_canonical_dir_is_a_no_op
test_existing_file_is_never_clobbered
test_tracked_path_is_refused
