#!/usr/bin/env bash
# tests/start-hybrid.test.sh - smoke test for cloud-workstation/start-hybrid.sh,
# the captain's-bridge session launcher. Everything runs against a scratch stack
# so the LIVE 'work' session and the real treehouse pool are never touched:
#   - a private tmux server (`-L` socket) behind a PATH shim, like
#     fm-backend-tmux-smoke.test.sh;
#   - a scratch HOME with stub git repos standing in for the primary checkout
#     and the leased worktrees;
#   - PATH stubs for treehouse (hands out the stub worktrees, no real lease),
#     claude (records its argv per tab), and mc (no-op);
#   - WORK_SESSION set to a scratch session name.
# Verifies: the coordinator tab gets --remote-control firstmate; wt tabs keep
# --remote-control <wt>; a clean worktree (with only the known setup drops) is
# moved to a detached HEAD at origin/master; a dirty worktree and a worktree
# with a local commit are left untouched with a visible warning; a re-run
# attaches instead of rebuilding.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/cloud-workstation/start-hybrid.sh"
[ -x "$SCRIPT" ] || fail "cloud-workstation/start-hybrid.sh is missing or not executable"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="start-hybrid-smoke-$$"

# Invoked via the EXIT trap below.
# shellcheck disable=SC2329
cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_all EXIT

TESTROOT=$(fm_test_tmproot start-hybrid)
fm_git_identity

# --- scratch HOME: primary checkout, firstmate dir, stub worktrees -----------

export HOME="$TESTROOT/home"
mkdir -p "$HOME/tools/firstmate" "$HOME/projects"

# Seed repo plays origin: c1, then (after the worktrees clone it) c2 on master.
SEED="$TESTROOT/seed"
git init -qb master "$SEED"
echo one > "$SEED/tracked.txt"
git -C "$SEED" add tracked.txt
git -C "$SEED" commit -qm c1

WTS="$TESTROOT/wts"
mkdir -p "$WTS"
for wt in wt1 wt2 wt3 gnhf; do
  git clone -q "$SEED" "$WTS/$wt"
done

echo two > "$SEED/tracked.txt"
git -C "$SEED" commit -aqm c2
C1=$(git -C "$SEED" rev-parse master~1)
C2=$(git -C "$SEED" rev-parse master)

# The primary checkout must exist (lease_wt cd's into it) but must never move.
git clone -q "$SEED" "$HOME/projects/optiroq-dev"
PRIMARY_HEAD=$(git -C "$HOME/projects/optiroq-dev" rev-parse HEAD)

# wt1: clean except the known setup drops - must sync to detached origin/master.
touch "$WTS/wt1/.env.e2e"
mkdir -p "$WTS/wt1/node_modules"
echo x > "$WTS/wt1/node_modules/x.js"

# wt2: uncommitted change to a tracked file - must be left exactly as-is.
echo local-change >> "$WTS/wt2/tracked.txt"

# wt3: local commit not on origin/master - must be left exactly as-is.
echo three > "$WTS/wt3/extra.txt"
git -C "$WTS/wt3" add extra.txt
git -C "$WTS/wt3" commit -qm local-c3
C3=$(git -C "$WTS/wt3" rev-parse HEAD)

# --- PATH stubs: tmux shim (private socket), treehouse, claude, mc -----------

STUB="$TESTROOT/stub"
mkdir -p "$STUB"

cat > "$STUB/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH

cat > "$STUB/treehouse" <<SH
#!/usr/bin/env bash
holder=bridge
prev=
for a in "\$@"; do
  [ "\$prev" = "--lease-holder" ] && holder=\$a
  prev=\$a
done
echo "$WTS/\$holder"
SH

cat > "$STUB/claude" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TESTROOT/argv-\${CLAUDE_TMUX_WINDOW:-none}"
SH

fm_fake_exit0 "$STUB" mc
chmod +x "$STUB/tmux" "$STUB/treehouse" "$STUB/claude"
PATH="$STUB:$PATH"
export PATH

# Pre-start the private server with a prep session and force plain non-login
# shells in every pane, so tab shells inherit this stub PATH instead of having
# a login profile reset it (which could resolve the real claude).
tmux new-session -d -s prep -x 200 -y 50 || fail "could not start the private tmux server"
tmux set -g default-command "bash --norc --noprofile" || fail "could not set default-command"

S="fmtest-$$"

wait_for_file() {
  local f=$1 tries=0
  while [ ! -e "$f" ]; do
    tries=$((tries + 1))
    [ "$tries" -gt 60 ] && return 1
    sleep 0.5
  done
}

# --- build run ----------------------------------------------------------------

out=$(WORK_SESSION="$S" "$SCRIPT" </dev/null 2>&1) || fail "build run failed: $out"
printf '%s\n' "$out" | grep -q "session '$S' created" \
  || fail "build run did not report creating the scratch session: $out"
pass "build run creates the scratch session"

# Sync runs synchronously at build, so worktree state is checkable immediately.
[ "$(git -C "$WTS/wt1" rev-parse HEAD)" = "$C2" ] \
  || fail "clean wt1 was not moved to origin/master"
git -C "$WTS/wt1" symbolic-ref -q HEAD >/dev/null \
  && fail "synced wt1 is on a branch, not a detached HEAD"
[ -f "$WTS/wt1/.env.e2e" ] && [ -f "$WTS/wt1/node_modules/x.js" ] \
  || fail "sync did not preserve wt1's known setup drops"
pass "clean worktree synced to a detached HEAD at origin/master, drops preserved"

[ "$(git -C "$WTS/wt2" rev-parse HEAD)" = "$C1" ] \
  || fail "dirty wt2's HEAD moved"
grep -q local-change "$WTS/wt2/tracked.txt" \
  || fail "dirty wt2's uncommitted change was lost"
pass "dirty worktree left exactly as-is"

[ "$(git -C "$WTS/wt3" rev-parse HEAD)" = "$C3" ] \
  || fail "wt3's local commit HEAD moved"
pass "worktree with a local commit left exactly as-is"

[ "$(git -C "$HOME/projects/optiroq-dev" rev-parse HEAD)" = "$PRIMARY_HEAD" ] \
  || fail "the primary checkout's HEAD moved"
pass "primary checkout untouched"

# --- per-tab claude argv and warnings ------------------------------------------

wait_for_file "$TESTROOT/argv-firstmate" || fail "coordinator tab never launched claude"
grep -q -- '--remote-control firstmate' "$TESTROOT/argv-firstmate" \
  || fail "coordinator claude argv lacks --remote-control firstmate: $(cat "$TESTROOT/argv-firstmate")"
grep -q -- '--dangerously-skip-permissions' "$TESTROOT/argv-firstmate" \
  || fail "coordinator claude argv lost --dangerously-skip-permissions"
pass "coordinator tab is remotely controllable as 'firstmate'"

for wt in wt1 wt2 wt3; do
  wait_for_file "$TESTROOT/argv-$wt" || fail "$wt tab never launched claude"
  grep -q -- "--remote-control $wt" "$TESTROOT/argv-$wt" \
    || fail "$wt claude argv lacks --remote-control $wt: $(cat "$TESTROOT/argv-$wt")"
done
pass "wt tabs keep --remote-control <wt>"

tmux capture-pane -p -t "$S:wt1" -S - | grep -q 'synced: detached HEAD' \
  || fail "wt1 tab does not show the synced note"
for wt in wt2 wt3; do
  tmux capture-pane -p -t "$S:$wt" -S - | grep -q 'WARNING' \
    || fail "$wt tab does not show the not-synced warning"
done
pass "sync note and not-synced warnings are visible in the tabs"

windows=$(tmux list-windows -t "$S" -F '#{window_name}' | tr '\n' ' ')
[ "$windows" = "firstmate wt1 wt2 wt3 gnhf mc " ] \
  || fail "unexpected window layout: $windows"
pass "window layout is firstmate wt1 wt2 wt3 gnhf mc"

# --- re-run: attach, never rebuild ---------------------------------------------

rm -f "$TESTROOT"/argv-*
out2=$(WORK_SESSION="$S" "$SCRIPT" </dev/null 2>&1)
printf '%s\n' "$out2" | grep -q "session '$S' created" \
  && fail "re-run rebuilt the session instead of attaching: $out2"
sleep 2
ls "$TESTROOT"/argv-* >/dev/null 2>&1 \
  && fail "re-run relaunched claude in the tabs"
[ "$(tmux list-windows -t "$S" -F '#{window_name}' | tr '\n' ' ')" = "$windows" ] \
  || fail "re-run changed the window layout"
pass "re-run attaches instead of rebuilding"

exit 0
