#!/usr/bin/env bash
# REAL-PANE tests for bin/fm-provision-lib.sh's wait. No stubbed probes: a real
# tmux server, a real pane, real processes, real timing.
#
# WHY THIS FILE EXISTS. tests/fm-provision.test.sh drives the same loop against
# SCRIPTED probes, and it passed while the code failed every real spawn - because
# the stub reported the pane BUSY from the very first tick, which is precisely
# what reality does not do. fm-spawn.sh sends `treehouse get` and calls straight
# into the wait, so the first probe lands ~35ms later, before the pane's shell
# (still running its rc files) has consumed the keystroke: no children yet, which
# reads identically to a command that exited. Measured with no grace, exactly as
# fm-spawn.sh sends: 10/10 first probes read `idle`, and the wait declared
# "treehouse gave up" on tick one.
#
# So this file reproduces the SPAWN SHAPE exactly - create the window, send, wait,
# with no settle anywhere - and is the regression guard for that class of bug. A
# scripted test cannot hold this line, because the thing under test IS the timing.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { pass "skipped: tmux not installed"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-provision-pane)
mkdir -p "$TMP_ROOT/proj" "$TMP_ROOT/worktree" "$TMP_ROOT/bin"
PROJ=$(cd "$TMP_ROOT/proj" && pwd -P)
WORKTREE=$(cd "$TMP_ROOT/worktree" && pwd -P)

# Our own tmux server: never touch the live fleet's panes.
SOCKET="fmprov$$"
TMUX_CLEANUP() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; fm_test_cleanup; }
trap TMUX_CLEANUP EXIT

# The lib talks to a bare `tmux`; shim it onto our private socket.
cat > "$TMP_ROOT/bin/tmux" <<SH
#!/usr/bin/env bash
exec $(command -v tmux) -L $SOCKET "\$@"
SH
chmod +x "$TMP_ROOT/bin/tmux"

# A driver that reproduces fm-spawn.sh:605-612 in shape: send the command, then
# call the wait immediately. The absence of any sleep here is the whole point.
cat > "$TMP_ROOT/bin/drive.sh" <<SH
#!/usr/bin/env bash
set -u
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/backends/tmux.sh"
. "$ROOT/bin/fm-provision-lib.sh"
fm_backend_tmux_send_text_line "\$2" "\$3"
if OUT=\$(fm_provision_wait "\$2" "\$1" "\${4:-60}" "\${5:-30}"); then
  echo "ENTERED \$OUT"
else
  echo "FAILED"
fi
SH
chmod +x "$TMP_ROOT/bin/drive.sh"

fresh_pane() {  # <window>
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  tmux -L "$SOCKET" new-session -d -s s -n "$1" -c "$PROJ"
}

drive() {  # <window> <command> [timeout] [stall]
  PATH="$TMP_ROOT/bin:$PATH" "$TMP_ROOT/bin/drive.sh" \
    "$PROJ" "s:$1" "$2" "${3:-60}" "${4:-30}" 2>/dev/null | tail -n 1
}

# --- (a) THE REGRESSION: a spawn-shaped acquire must not die on tick one -------
# Window created and command sent with NO grace, exactly as fm-spawn.sh does it.
# Before the settle/confirm guard this failed every time: the first probe saw a
# shell with no children and called it "treehouse gave up".
fails=0
for _ in 1 2 3; do
  fresh_pane w
  out=$(drive w "sleep 2; cd '$WORKTREE'" 60 30)
  case "$out" in
    "ENTERED $WORKTREE") ;;
    *) fails=$((fails + 1)) ;;
  esac
done
[ "$fails" -eq 0 ] || fail "(a) a spawn-shaped acquire must survive its first probe ($fails/3 died on an unsettled idle pane)"
pass "(a) a real spawn-shaped acquire is not killed by the not-yet-started shell"

# --- (b) a slow (cold-install-shaped) pane is still waited out ----------------
fresh_pane w
out=$(drive w "echo '[post_create] installing deps'; sleep 8; cd '$WORKTREE'" 90 60)
[ "$out" = "ENTERED $WORKTREE" ] || fail "(b) a slow install must be waited out, got: $out"
pass "(b) a real slow install is waited out and yields the worktree"

# --- (c) a REALLY failed acquire is still caught, and quickly ------------------
# The guard must not turn a real failure into a hang: an idle pane that STAYS idle
# is still called out, in seconds, well inside the ceiling.
fresh_pane w
start=$(date +%s)
out=$(drive w "echo 'error: all 16 worktrees are in use or dirty (max_trees = 16)'" 120 90)
elapsed=$(( $(date +%s) - start ))
[ "$out" = FAILED ] || fail "(c) a pane whose command exited without a worktree must fail, got: $out"
[ "$elapsed" -lt 30 ] || fail "(c) a real failure must be caught in seconds, took ${elapsed}s"
pass "(c) a real failed acquire is still caught fast (${elapsed}s), not turned into a hang"
