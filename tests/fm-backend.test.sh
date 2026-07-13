#!/usr/bin/env bash
# tests/fm-backend.test.sh - runtime-backend conformance.
# bin/fm-backend.sh and bin/backends/tmux.sh own the tmux command sequences that
# fm-send.sh, fm-peek.sh, fm-spawn.sh, and fm-teardown.sh dispatch through. This
# suite:
#
#   1. Unit-tests bin/fm-backend.sh's selection, meta, and dispatch helpers.
#   2. Runs the PRE-REFACTOR versions of fm-send.sh, fm-peek.sh, fm-spawn.sh,
#      and fm-teardown.sh (checked out from the merge-base with `main`, the
#      commit this branch started from) against the SAME fake tmux/treehouse
#      binaries and fixtures as the versions in this checkout, then diffs the
#      two command logs byte-for-byte, so the tmux path cannot silently drift.
#   3. Asserts the backend validators still refuse an unknown backend loudly.
#
# fm-watch.sh's signal/stale/check/heartbeat wake-string contract is exercised
# end-to-end by tests/fm-watch-triage.test.sh and tests/wake-helpers.sh (same
# fake-tmux convention); this suite adds one direct old-vs-new diff for the
# stale-pane path specifically, since that wake path calls through
# fm_backend_capture instead of tmux directly.
# The real tmux smoke test (create session, send text + Enter, capture, list,
# kill) lives in tests/fm-backend-tmux-smoke.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-tests)
# fm_test_tmproot registers its cleanup trap inside the command-substitution
# subshell, so the root it just made is removed when that subshell exits. Every
# suite works around this by mkdir -p'ing its own case dirs; this one writes
# fixtures directly into the root, so recreate it once here.
mkdir -p "$TMP_ROOT"

# The commit this branch started from - the P1 "current main" baseline.
resolve_base_ref() {
  local ref base
  for ref in main refs/heads/main origin/main refs/remotes/origin/main origin/HEAD refs/remotes/origin/HEAD; do
    if git -C "$ROOT" rev-parse --verify -q "$ref^{commit}" >/dev/null; then
      base=$(git -C "$ROOT" merge-base HEAD "$ref" 2>/dev/null) || continue
      [ -n "$base" ] || continue
      printf '%s\n' "$base"
      return 0
    fi
  done
  return 1
}
BASE_REF=$(resolve_base_ref) \
  || fail "fm-backend baseline requires local main or origin/main; fetch the default branch before running this test"

# --- shared: a pre-refactor bin/ shim --------------------------------------
#
# build_old_bin echoes a directory whose bin/ subdir holds the PRE-REFACTOR
# fm-send.sh, fm-peek.sh, fm-watch.sh, fm-spawn.sh, and fm-teardown.sh
# (extracted from BASE_REF), plus symlinks to every OTHER sibling script those
# five source - all unchanged by this task, so the real files are exactly
# what BASE_REF would have used too. FM_ROOT_OVERRIDE pointed at this dir's
# root makes "$FM_ROOT/bin/fm-project-mode.sh" (etc.) resolve correctly.
# fm-backend.sh (and its bin/backends/ adapters) is the dispatcher every one
# of the five REFACTORED scripts sources; it must be a real, reachable file in
# the old bin/ too or `. "$SCRIPT_DIR/fm-backend.sh"` aborts under set -eu -
# hence it is a symlinked sibling, not an extracted-from-BASE_REF file: for a
# tmux-only conformance run the tmux adapter's behavior is what is under test,
# and that is unchanged by any later (e.g. non-tmux backend) addition to
# fm-backend.sh's own dispatch surface.
OLD_BIN_UNCHANGED_SIBLINGS="fm-guard.sh fm-lock-lib.sh fm-tangle-lib.sh fm-tmux-lib.sh fm-composer-lib.sh fm-marker-lib.sh fm-wake-lib.sh fm-classify-lib.sh fm-ff-lib.sh fm-config-inherit-lib.sh fm-tasks-axi-lib.sh fm-project-mode.sh fm-harness.sh fm-crew-state.sh fm-backend.sh"
OLD_BIN_REFACTORED="fm-send.sh fm-peek.sh fm-watch.sh fm-spawn.sh fm-teardown.sh"

build_old_bin() {  # <name> -> echoes root dir (root/bin/<script> is the entry point)
  local name=$1 root bin f
  root="$TMP_ROOT/$name"
  bin="$root/bin"
  mkdir -p "$bin"
  for f in $OLD_BIN_UNCHANGED_SIBLINGS; do
    ln -s "$ROOT/bin/$f" "$bin/$f"
  done
  ln -s "$ROOT/bin/backends" "$bin/backends"
  for f in $OLD_BIN_REFACTORED; do
    # Strip the gate-refuse source+call from the extracted baseline. That guard
    # existed only to keep a no-mistakes GATE agent from driving the fleet; the
    # pipeline is gone, so bin/fm-gate-refuse-lib.sh no longer exists and the old
    # script's `. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"` would abort under set -eu.
    # Removing it does not weaken the conformance check: this test compares the
    # emitted tmux command shape, which the guard never touched.
    # shellcheck disable=SC2016  # single quotes are deliberate: these are grep patterns matching the literal text "$SCRIPT_DIR" in the extracted script, not an expansion.
    git -C "$ROOT" show "$BASE_REF:bin/$f" \
      | grep -v '^# shellcheck source=bin/fm-gate-refuse-lib\.sh$' \
      | grep -v '^\. "\$SCRIPT_DIR/fm-gate-refuse-lib\.sh"$' \
      | grep -v '^fm_refuse_if_gate_agent$' \
      > "$bin/$f"
    chmod +x "$bin/$f"
  done
  printf '%s\n' "$root"
}

# --- fm-backend.sh unit tests ------------------------------------------------

test_backend_name_is_always_tmux() {
  # tmux is the only backend: fm_backend_name resolves it unconditionally, with
  # no env override, no config file, and no runtime auto-detection to consult.
  [ "$(fm_backend_name)" = tmux ] || fail "fm_backend_name should always resolve tmux"
  [ "$(FM_BACKEND=herdr fm_backend_name)" = tmux ] \
    || fail "a stale FM_BACKEND value must not resurrect a removed backend"
  pass "fm_backend_name: always tmux"
}

test_backend_validate_refuses_unknown() {
  local out
  fm_backend_validate tmux 2>/dev/null || fail "fm_backend_validate should accept tmux"
  # Every removed backend is now simply unknown, exactly like a typo.
  for name in bogus codex-app herdr zellij orca cmux; do
    out=$(fm_backend_validate "$name" 2>&1) && fail "fm_backend_validate should refuse '$name'"
    assert_contains "$out" "unknown backend '$name'" "fm_backend_validate did not name the rejected backend"
  done
  out=$(fm_backend_validate "tmux herdr" 2>&1) && fail "fm_backend_validate should refuse a multi-token backend name"
  assert_contains "$out" "unknown backend 'tmux herdr'" "fm_backend_validate accepted a multi-token backend name"
  pass "fm_backend_validate: tmux accepted, every other name refused loudly"
}

test_backend_source_shell_portable() {
  local out
  # zsh does not word-split unquoted expansions; sourcing fm-backend.sh from
  # an interactive zsh session must still recognize the backend name.
  if command -v zsh >/dev/null 2>&1; then
    zsh -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source tmux && whence -w fm_backend_tmux_capture >/dev/null" 2>/dev/null \
      || fail "zsh: fm_backend_source tmux should load the adapter when sourced"
    out=$(zsh -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source bogus" 2>&1) \
      && fail "zsh: fm_backend_source bogus should fail"
    assert_contains "$out" "unknown backend 'bogus'" \
      "zsh: fm_backend_source did not reject bogus with the expected error"
    pass "zsh: fm_backend_source loads tmux and rejects unknown backends"
  else
    pass "zsh: shell-portable backend matching skipped (zsh not found)"
  fi

  bash -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source tmux && declare -F fm_backend_tmux_capture >/dev/null" 2>/dev/null \
    || fail "bash: fm_backend_source tmux should load the adapter when sourced"
  out=$(bash -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source bogus" 2>&1) \
    && fail "bash: fm_backend_source bogus should fail"
  assert_contains "$out" "unknown backend 'bogus'" \
    "bash: fm_backend_source did not reject bogus with the expected error"
  pass "bash: fm_backend_source loads tmux and rejects unknown backends"
}

test_backend_validate_spawn_accepts_tmux_only() {
  local out
  fm_backend_validate_spawn tmux 2>/dev/null || fail "fm_backend_validate_spawn should accept tmux"
  out=$(fm_backend_validate_spawn bogus 2>&1) && fail "fm_backend_validate_spawn should refuse unknown backends"
  assert_contains "$out" "unknown backend 'bogus'" "fm_backend_validate_spawn did not preserve unknown-backend validation"
  out=$(fm_backend_validate_spawn herdr 2>&1) && fail "fm_backend_validate_spawn should refuse a removed backend"
  assert_contains "$out" "unknown backend 'herdr'" "fm_backend_validate_spawn accepted a removed backend"
  pass "fm_backend_validate_spawn: tmux is the only spawn-capable backend"
}

test_meta_get_and_backend_of_meta() {
  local meta=$TMP_ROOT/meta-get.meta
  fm_write_meta "$meta" "window=firstmate:fm-x1" "harness=claude"
  [ "$(fm_meta_get "$meta" window)" = "firstmate:fm-x1" ] || fail "fm_meta_get did not read window="
  [ "$(fm_meta_get "$meta" missing)" = "" ] || fail "fm_meta_get should print nothing for an absent key"
  [ "$(fm_backend_of_meta "$meta")" = tmux ] || fail "fm_backend_of_meta should default absent backend= to tmux"

  printf 'backend=tmux\n' >> "$meta"
  [ "$(fm_backend_of_meta "$meta")" = tmux ] || fail "fm_backend_of_meta should read an explicit backend=tmux"

  pass "fm_meta_get / fm_backend_of_meta: read key=value, default backend to tmux"
}

test_resolve_selector_three_forms() {
  local state=$TMP_ROOT/resolve-state fakebin out
  mkdir -p "$state"
  fm_write_meta "$state/task1.meta" "window=firstmate:fm-task1"
  fm_write_meta "$state/dotfiles-d6.meta" "window=firstmate:fm-dotfiles-d6"
  fm_write_meta "$state/fm-turnend-all-harnesses-v9.meta" "window=firstmate:fm-turnend-all-harnesses-v9"

  [ "$(fm_backend_resolve_selector 'sess:win' "$state")" = "sess:win" ] \
    || fail "explicit session:window should be used as-is"

  [ "$(fm_backend_resolve_selector 'dotfiles-d6' "$state")" = "firstmate:fm-dotfiles-d6" ] \
    || fail "bare non-fm task id should resolve through exact metadata"
  [ "$(fm_backend_of_selector 'dotfiles-d6' 'firstmate:fm-dotfiles-d6' "$state")" = tmux ] \
    || fail "bare non-fm task id should report the tmux backend"
  [ "$(fm_backend_expected_label_of_selector 'dotfiles-d6' "$state")" = "fm-dotfiles-d6" ] \
    || fail "bare non-fm task id should report the spawned fm-<id> label"

  [ "$(fm_backend_resolve_selector 'fm-turnend-all-harnesses-v9' "$state")" = "firstmate:fm-turnend-all-harnesses-v9" ] \
    || fail "exact fm-* task id should resolve through its exact metadata"
  [ "$(fm_backend_expected_label_of_selector 'fm-turnend-all-harnesses-v9' "$state")" = "fm-fm-turnend-all-harnesses-v9" ] \
    || fail "exact fm-* task id should report the spawned fm-<id> label"

  [ "$(fm_backend_resolve_selector 'fm-task1' "$state")" = "firstmate:fm-task1" ] \
    || fail "legacy fm-<id> label should resolve through <id>.meta's window="
  [ "$(fm_backend_expected_label_of_selector 'fm-task1' "$state")" = "fm-task1" ] \
    || fail "legacy fm-<id> label should preserve its backend label"

  out=$(fm_backend_resolve_selector 'fm-missing' "$state" 2>&1) && fail "fm-<id> with no meta should fail"
  assert_contains "$out" "no metadata for fm-missing" "missing-meta error text changed"

  fakebin="$TMP_ROOT/resolve-fakebin"; mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'firstmate:adhoc\nother:otherwin\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  out=$(PATH="$fakebin:$PATH" fm_backend_resolve_selector 'fm-adhoc' "$state" 2>&1) || true
  # fm-adhoc carries no meta file, so it is NOT the bare-name fallback path - it
  # is the fm-* meta-miss error path after exact-id and legacy-label metadata
  # lookup both miss.
  # Only a NON fm-* bare name falls through to the live-window search.
  assert_contains "$out" "no metadata for fm-adhoc" "an fm-* selector must always require meta, not silently fall back to a live search"

  out=$(PATH="$fakebin:$PATH" fm_backend_resolve_selector 'adhoc' "$state")
  [ "$out" = "firstmate:adhoc" ] || fail "an ad hoc bare name should resolve via the tmux live-window fallback, got '$out'"

  pass "fm_backend_resolve_selector: session:window literal, exact task id first, legacy fm-<id> label fallback, ad hoc bare name via tmux list-windows"
}

test_backend_of_selector_matches_explicit_target_meta() {
  local state=$TMP_ROOT/backend-selector-state
  mkdir -p "$state"
  fm_write_meta "$state/dotfiles-d6.meta" "window=firstmate:fm-dotfiles-d6"
  fm_write_meta "$state/tmux-task.meta" "window=firstmate:fm-tmux-task"
  fm_write_meta "$state/custom-window-task.meta" "window=custom-window"

  [ "$(fm_backend_of_selector 'dotfiles-d6' 'firstmate:fm-dotfiles-d6' "$state")" = tmux ] \
    || fail "bare non-fm task id selector should resolve its metadata backend"
  [ "$(fm_backend_resolve_selector 'custom-window' "$state")" = custom-window ] \
    || fail "raw window selector matching metadata should not require the tmux live-window fallback"
  [ "$(fm_backend_of_selector 'firstmate:fm-tmux-task' 'firstmate:fm-tmux-task' "$state")" = tmux ] \
    || fail "explicit tmux-shaped target with absent backend= should default to tmux"
  [ "$(fm_backend_of_selector 'manual:outside' 'manual:outside' "$state")" = tmux ] \
    || fail "explicit target with no matching metadata should keep the tmux compatibility default"

  pass "fm_backend_of_selector: exact task ids, legacy fm-<id> labels, and matching explicit targets resolve through metadata"
}

# --- old vs new: fm-send.sh --------------------------------------------------

make_send_fakebin() {  # <dir> -> echoes fakebin dir; logs every tmux call to $FM_TMUX_LOG
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_TMUX_LOG:?}"
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

run_send_case() {  # <bin-root> <fakebin> <log> <home> -- <send args...>
  local bin=$1 fb=$2 log=$3 home=$4; shift 4
  [ "${1:-}" = -- ] && shift
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$bin" FM_HOME="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$bin/bin/fm-send.sh" "$@" >/dev/null 2>&1
}

strip_send_preflight() {  # <log>
  local preflight
  preflight=$'tmux\x1fdisplay-message\x1f-p\x1f-t\x1fsess:win\x1f#{pane_id}'
  awk -v preflight="$preflight" '$0 != preflight { print }' "$1"
}

test_send_conformance_old_vs_new() {
  local old_bin fb log_old log_new home rc_old rc_new filtered_old filtered_new
  old_bin=$(build_old_bin send-old)
  fb=$(make_send_fakebin "$TMP_ROOT/send-fake")
  home="$TMP_ROOT/send-home"; mkdir -p "$home/state"
  log_old="$TMP_ROOT/send-old.log"; log_new="$TMP_ROOT/send-new.log"
  filtered_old="$TMP_ROOT/send-old.filtered.log"; filtered_new="$TMP_ROOT/send-new.filtered.log"

  # Case 1: --key path.
  run_send_case "$old_bin" "$fb" "$log_old" "$home" -- "sess:win" --key Escape
  rc_old=$?
  run_send_case "$ROOT" "$fb" "$log_new" "$home" -- "sess:win" --key Escape
  rc_new=$?
  expect_code "$rc_old" "$rc_new" "fm-send --key: old vs new exit code"
  assert_contains "$(cat "$log_new")" $'\x1f''display-message'$'\x1f''-p'$'\x1f''-t'$'\x1f''sess:win'$'\x1f''#{pane_id}' \
    "fm-send --key did not verify the explicit tmux target before sending"
  strip_send_preflight "$log_old" > "$filtered_old"
  strip_send_preflight "$log_new" > "$filtered_new"
  diff -u "$filtered_old" "$filtered_new" > "$TMP_ROOT/send-diff-key.txt" 2>&1 \
    || fail "fm-send --key: tmux command log differs old vs new"$'\n'"$(cat "$TMP_ROOT/send-diff-key.txt")"
  assert_contains "$(cat "$log_new")" $'\x1f''Escape' "fm-send --key did not send the named key"

  # Case 2: plain text (0.3s settle, no popup).
  run_send_case "$old_bin" "$fb" "$log_old" "$home" -- "sess:win" hello captain
  rc_old=$?
  run_send_case "$ROOT" "$fb" "$log_new" "$home" -- "sess:win" hello captain
  rc_new=$?
  expect_code "$rc_old" "$rc_new" "fm-send plain text: old vs new exit code"
  strip_send_preflight "$log_old" > "$filtered_old"
  strip_send_preflight "$log_new" > "$filtered_new"
  diff -u "$filtered_old" "$filtered_new" > "$TMP_ROOT/send-diff-plain.txt" 2>&1 \
    || fail "fm-send plain text: tmux command log differs old vs new"$'\n'"$(cat "$TMP_ROOT/send-diff-plain.txt")"
  assert_contains "$(cat "$log_new")" $'\x1f''send-keys'$'\x1f''-t'$'\x1f''sess:win'$'\x1f''-l'$'\x1f''hello captain' \
    "fm-send did not send the literal text with send-keys -l"
  assert_contains "$(cat "$log_new")" $'\x1f''Enter' "fm-send did not submit with Enter"

  # Case 3: a slash command still opens the popup-settle path (verified
  # elsewhere in tests/fm-send-popup-settle.test.sh) and still ends in the
  # same tmux command shape: send-keys -l, then a retried Enter.
  run_send_case "$old_bin" "$fb" "$log_old" "$home" -- "sess:win" /some-skill
  rc_old=$?
  run_send_case "$ROOT" "$fb" "$log_new" "$home" -- "sess:win" /some-skill
  rc_new=$?
  expect_code "$rc_old" "$rc_new" "fm-send /skill: old vs new exit code"
  strip_send_preflight "$log_old" > "$filtered_old"
  strip_send_preflight "$log_new" > "$filtered_new"
  diff -u "$filtered_old" "$filtered_new" > "$TMP_ROOT/send-diff-slash.txt" 2>&1 \
    || fail "fm-send /skill: tmux command log differs old vs new"$'\n'"$(cat "$TMP_ROOT/send-diff-slash.txt")"

  pass "fm-send.sh: explicit tmux targets are verified, while --key/plain/slash send command shape stays old-compatible"
}

# --- old vs new: fm-peek.sh --------------------------------------------------

make_peek_fakebin() {  # <dir> <capture-output> -> echoes fakebin dir
  local dir=$1 payload=$2 fb="$1/fakebin"
  mkdir -p "$fb"
  printf '%s' "$payload" > "$dir/capture.out"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "\$@"; do printf '\\x1f%s' "\$a"; done; printf '\\n'; } >> "\${FM_TMUX_LOG:?}"
case "\${1:-}" in
  capture-pane) cat "$dir/capture.out" ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

test_peek_conformance_old_vs_new() {
  local old_bin fb log_old log_new home out_old out_new payload neutral_root
  payload=$'line one\nline two\ncaptain on deck'
  old_bin=$(build_old_bin peek-old)
  fb=$(make_peek_fakebin "$TMP_ROOT/peek-fake" "$payload")
  home="$TMP_ROOT/peek-home"; mkdir -p "$home/state"
  log_old="$TMP_ROOT/peek-old.log"; log_new="$TMP_ROOT/peek-new.log"
  # A fresh non-git dir keeps fm-guard.sh's worktree-tangle check inert (it warns
  # to stderr, discarded below) - neither run needs FM_ROOT for anything beyond
  # that guard, since STATE/HOME are already overridden directly.
  neutral_root="$TMP_ROOT/peek-neutral-root"; mkdir -p "$neutral_root"

  : > "$log_old"
  out_old=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral_root" FM_HOME="$home" FM_TMUX_LOG="$log_old" \
    "$old_bin/bin/fm-peek.sh" "sess:win" 25 2>/dev/null)
  : > "$log_new"
  out_new=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral_root" FM_HOME="$home" FM_TMUX_LOG="$log_new" \
    "$ROOT/bin/fm-peek.sh" "sess:win" 25 2>/dev/null)

  [ "$out_old" = "$out_new" ] || fail "fm-peek output differs old vs new"$'\n'"--- old ---"$'\n'"$out_old"$'\n'"--- new ---"$'\n'"$out_new"
  [ "$out_new" = "$payload" ] || fail "fm-peek did not pass through the fake capture-pane output exactly"
  diff -u "$log_old" "$log_new" > "$TMP_ROOT/peek-diff.txt" 2>&1 \
    || fail "fm-peek: tmux command log differs old vs new"$'\n'"$(cat "$TMP_ROOT/peek-diff.txt")"
  assert_contains "$(cat "$log_new")" $'\x1f''capture-pane'$'\x1f''-p'$'\x1f''-t'$'\x1f''sess:win'$'\x1f''-S'$'\x1f''-25' \
    "fm-peek did not call capture-pane -p -t <target> -S -<lines> exactly"

  pass "fm-peek.sh: capture-pane invocation and output are byte-identical old vs new"
}

# --- old vs new: fm-spawn.sh --------------------------------------------------

make_spawn_fakebin() {  # <dir> <fake-worktree-path> -> echoes fakebin dir
  local dir=$1 wt=$2 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "\$@"; do printf '\\x1f%s' "\$a"; done; printf '\\n'; } >> "\${FM_TMUX_LOG:?}"
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_path*) printf '%s\\n' "$wt"; exit 0 ;; esac; done
    printf 'firstmate\\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_fake_exit0 "$fb" treehouse
  printf '%s\n' "$fb"
}

run_spawn_case() {  # <bin-root> <fakebin> <log> <state> <data> <config> <proj> -- <spawn args...>
  local bin=$1 fb=$2 log=$3 state=$4 data=$5 config=$6 proj=$7; shift 7
  [ "${1:-}" = -- ] && shift
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$bin" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_TMUX_LOG="$log" \
    "$bin/bin/fm-spawn.sh" "$@"
}

# NOTE: the old-vs-new spawn command-log conformance test that used to live here
# was retired. It asserted the P1 backend refactor was a byte-for-byte pure
# extraction of the spawn window-creation/targeting sequence, but that sequence
# is now DELIBERATELY changed: fm-spawn drives the tmux backend to capture a
# stable window id, pin the window name (automatic-rename/allow-rename off), and
# target that id for the rename-critical spawn steps (robustness under a
# captain's non-default tmux config). A byte-identical old-vs-new diff can no
# longer hold there by design. That intended sequence is now authoritatively and
# comprehensively verified - via a recording fake-tmux - by
# tests/fm-tangle-guard.test.sh ("fm-spawn: appends windows by session-colon,
# pins the name, and targets the window id"), and the real tmux create/kill path
# by tests/fm-backend-tmux-smoke.test.sh. The send/peek/teardown conformance
# tests below remain pure extractions and stay. (make_spawn_fakebin and
# run_spawn_case are retained: test_spawn_default_backend_writes_no_meta_field
# uses make_spawn_fakebin, and #294's run_spawn_symlink_case uses run_spawn_case.)

# --- symlinked project prefix must not false-refuse the isolation guard -----
#
# A real backend's pane_current_path read reports the OS-level
# PHYSICALLY-resolved cwd. When the project
# itself lives under a symlinked prefix (e.g. macOS's /tmp -> /private/tmp),
# fm-spawn.sh's PROJ_ABS - a logical `cd && pwd` - differs string-for-string
# from that physical read even before treehouse moves the pane at all, so the
# worktree-discovery poll used to mistake an UNMOVED pane for one that had
# already left the project, handing validate_spawn_worktree the project's own
# directory as "the worktree" and tripping its false isolation refusal.
# make_spawn_symlink_fakebin's tmux stub returns an unmoved project path on the
# first pane_current_path poll, then the real worktree path from the second poll
# onward, so this test fails loudly if the PROJ_ABS/PROJ_ABS_REAL
# canonicalization in bin/fm-spawn.sh ever regresses.
make_spawn_symlink_fakebin() {  # <dir> <initial-project-path> <worktree-path> -> echoes fakebin dir
  local dir=$1 initial_path=$2 wt=$3 fb="$1/fakebin" counter="$1/poll-count"
  mkdir -p "$fb"
  : > "$counter"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "\$@"; do printf '\\x1f%s' "\$a"; done; printf '\\n'; } >> "\${FM_TMUX_LOG:?}"
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_path*)
      printf x >> "$counter"
      if [ "\$(wc -c < "$counter")" -le 1 ]; then
        printf '%s\\n' "$initial_path"
      else
        printf '%s\\n' "$wt"
      fi
      exit 0
    ;; esac; done
    printf 'firstmate\\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_fake_exit0 "$fb" treehouse
  printf '%s\n' "$fb"
}

run_spawn_symlink_case() {  # <label> <physical|logical>
  local label=$1 first_reply=$2 real_root link_root proj wt id fb data state config log out rc proj_phys initial_path
  real_root="$TMP_ROOT/symlink-real-$label"; link_root="$TMP_ROOT/symlink-link-$label"
  mkdir -p "$real_root"
  ln -s "$real_root" "$link_root"
  proj="$link_root/proj"
  wt="$TMP_ROOT/symlink-wt-$label"
  id="spawnsymlink$label"
  fm_git_worktree "$real_root/proj" "$wt" "fm/$id"
  # TMP_ROOT itself can already sit behind an OS-level symlink (e.g. macOS's
  # /var -> /private/var), so resolve the fakebin's "physical" reply with
  # pwd -P rather than string concatenation - it must match exactly what
  # fm-spawn.sh's own PROJ_ABS_REAL computes, including any symlink layers
  # ABOVE this test's own synthetic real_root/link_root pair.
  proj_phys=$(cd "$real_root/proj" && pwd -P)
  case "$first_reply" in
    physical) initial_path=$proj_phys ;;
    logical) initial_path=$proj ;;
    *) fail "unknown symlink first-reply mode: $first_reply" ;;
  esac
  fb=$(make_spawn_symlink_fakebin "$TMP_ROOT/symlink-fake-$label" "$initial_path" "$wt")
  data="$TMP_ROOT/symlink-data-$label"
  mkdir -p "$data/$id"
  printf 'test brief content\n' > "$data/$id/brief.md"
  state="$TMP_ROOT/symlink-state-$label"; config="$TMP_ROOT/symlink-config-$label"
  mkdir -p "$state" "$config"
  log="$TMP_ROOT/symlink-spawn-$label.log"

  out=$(run_spawn_case "$ROOT" "$fb" "$log" "$state" "$data" "$config" "$proj" -- "$id" "$proj" claude 2>&1)
  rc=$?
  expect_code 0 "$rc" "fm-spawn.sh should succeed for a project reached through a symlinked prefix when the backend reports $first_reply cwd"$'\n'"$out"
  assert_contains "$out" "worktree=$wt" \
    "fm-spawn.sh did not resolve a symlinked-prefix project to its real worktree when the backend reports $first_reply cwd"

  rm -rf "/tmp/fm-$id"
}

test_spawn_symlinked_project_prefix_avoids_false_refusal() {
  run_spawn_symlink_case physical physical
  run_spawn_symlink_case logical logical
  pass "fm-spawn.sh: a project reached through a symlinked prefix (e.g. macOS /tmp -> /private/tmp) does not trip the isolation guard's false refusal"
}

# --- old vs new: fm-teardown.sh ----------------------------------------------

make_teardown_fakebin() {  # <dir> -> echoes fakebin dir; logs tmux+treehouse calls
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_TMUX_LOG:?}"
exit 0
SH
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'treehouse'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_TMUX_LOG:?}"
exit 0
SH
  chmod +x "$fb/tmux" "$fb/treehouse"
  printf '%s\n' "$fb"
}

# run_teardown_case <script> <fm-root-override> <fakebin> <log> <state> <data> <config> <id>
# FM_ROOT_OVERRIDE is passed separately from <script> so both the old and new
# runs can point it at the SAME neutral (non-git) shim root - that root's
# bin/fm-guard.sh is a symlink to the real, unchanged script, so the
# worktree-tangle check runs identically (and silently) for both, regardless
# of which fm-teardown.sh (old or new) is actually being invoked.
run_teardown_case() {
  local script=$1 fmroot=$2 fb=$3 log=$4 state=$5 data=$6 config=$7 id=$8
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$fmroot" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_TMUX_LOG="$log" \
    "$script" "$id"
}

test_teardown_conformance_old_vs_new() {
  local old_bin fb proj wt id
  local state_old state_new config_old config_new data log_old log_new out_old out_new rc_old rc_new
  old_bin=$(build_old_bin teardown-old)
  proj="$TMP_ROOT/teardown-project"; wt="$TMP_ROOT/teardown-wt"
  id="teardownconform1"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fb=$(make_teardown_fakebin "$TMP_ROOT/teardown-fake")

  data="$TMP_ROOT/teardown-data"
  mkdir -p "$data/$id"
  printf 'scout findings\n' > "$data/$id/report.md"

  state_old="$TMP_ROOT/teardown-state-old"; state_new="$TMP_ROOT/teardown-state-new"
  config_old="$TMP_ROOT/teardown-config-old"; config_new="$TMP_ROOT/teardown-config-new"
  mkdir -p "$state_old" "$state_new" "$config_old" "$config_new"

  fm_write_meta "$state_old/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off"
  fm_write_meta "$state_new/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off"
  touch "$state_old/.last-watcher-beat" "$state_new/.last-watcher-beat"

  log_old="$TMP_ROOT/teardown-old.log"; log_new="$TMP_ROOT/teardown-new.log"
  out_old=$(run_teardown_case "$old_bin/bin/fm-teardown.sh" "$old_bin" "$fb" "$log_old" "$state_old" "$data" "$config_old" "$id" 2>&1)
  rc_old=$?
  out_new=$(run_teardown_case "$ROOT/bin/fm-teardown.sh" "$old_bin" "$fb" "$log_new" "$state_new" "$data" "$config_new" "$id" 2>&1)
  rc_new=$?

  expect_code 0 "$rc_old" "old fm-teardown.sh (scout, report present) should succeed"$'\n'"$out_old"
  expect_code 0 "$rc_new" "new fm-teardown.sh (scout, report present) should succeed"$'\n'"$out_new"
  diff -u "$log_old" "$log_new" > "$TMP_ROOT/teardown-diff.txt" 2>&1 \
    || fail "fm-teardown.sh: tmux+treehouse command log differs old vs new"$'\n'"$(cat "$TMP_ROOT/teardown-diff.txt")"
  assert_contains "$(cat "$log_new")" "treehouse"$'\x1f''return'$'\x1f''--force'$'\x1f'"$wt" \
    "teardown did not call treehouse return --force <worktree>"
  assert_contains "$(cat "$log_new")" "tmux"$'\x1f''kill-window'$'\x1f''-t'$'\x1f'"firstmate:fm-$id" \
    "teardown did not call tmux kill-window -t <window>"

  pass "fm-teardown.sh: treehouse return + tmux kill-window command log is byte-identical old vs new for a scout task"
}

# --- backend selection loudly refuses an unknown backend --------------------

test_spawn_default_backend_writes_no_meta_field() {
  local proj wt data id state config out
  proj="$TMP_ROOT/nobackend-project"; wt="$TMP_ROOT/nobackend-wt"; data="$TMP_ROOT/nobackend-data"
  id="nobackendz3"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  local fb
  fb=$(make_spawn_fakebin "$TMP_ROOT/nobackend-fake" "$wt")
  mkdir -p "$data/$id"; printf 'brief\n' > "$data/$id/brief.md"
  state="$TMP_ROOT/nobackend-state"; config="$TMP_ROOT/nobackend-config"
  mkdir -p "$state" "$config"

  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_TMUX_LOG="$TMP_ROOT/nobackend.log" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude 2>&1)
  expect_code 0 $? "the default spawn should succeed"$'\n'"$out"
  assert_no_grep 'backend=' "$state/$id.meta" \
    "a spawn must not write backend= to meta (an absent backend= means tmux)"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh: a spawn writes no backend= field (missing means tmux)"
}

test_backend_name_is_always_tmux
test_backend_validate_refuses_unknown
test_backend_source_shell_portable
test_backend_validate_spawn_accepts_tmux_only
test_meta_get_and_backend_of_meta
test_resolve_selector_three_forms
test_backend_of_selector_matches_explicit_target_meta
test_send_conformance_old_vs_new
test_peek_conformance_old_vs_new
test_spawn_symlinked_project_prefix_avoids_false_refusal
test_teardown_conformance_old_vs_new
test_spawn_default_backend_writes_no_meta_field
