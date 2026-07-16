#!/usr/bin/env bash
#
# start-hybrid.sh - the "captain's bridge": one persistent tmux session you launch on
# first connect and re-attach to after any disconnect. Layout:
#
#   [firstmate]     the coordinator - a Claude session inside ~/tools/firstmate,
#                   remotely controllable as 'firstmate' (claude.ai/code, mobile)
#   [wt1 wt2 wt3]   three durable worktrees of the master project (optiroq-dev),
#                   synced to the latest origin/master at session build when safe
#   [gnhf]          a fresh worktree, ready to launch overnight gnhf loops (usage hint printed)
#   [allma-core]    platform monorepo tab (created only when the clone exists)
#   [mc]            Midnight Commander for quick file ops / running commands
#
# Usage (on the box):
#   ~/cloud-workstation/start-hybrid.sh          # launch / re-attach the session
#   ~/cloud-workstation/start-hybrid.sh kill     # tear the session down
#
# Persistence: the tmux server keeps this session (and every running agent) alive across
# SSH disconnects. Re-running the command just re-attaches - it never rebuilds, and never
# resyncs, a live session.
#
# Worktree sync contract (session BUILD only): before launching Claude in a wt tab, the
# leased worktree is moved to the latest origin/master ONLY when that provably cannot
# lose work: no uncommitted changes, no untracked files beyond the known setup drops
# (.env.e2e at the root, node_modules anywhere - see worktree-setup.sh), and no local
# commits missing from origin/master. Anything else leaves the worktree exactly as-is
# with a loud warning in its tab: a stale worktree is strictly better than lost work,
# so there is never a `reset --hard` or `clean -fd` here. Worktrees of one repo cannot
# all check out the branch 'master' at once, so the synced shape is a detached HEAD at
# origin/master (treehouse worktrees are already detached).
#
# WORK_SESSION overrides the tmux session name (default 'work') so the script can be
# smoke-tested against a scratch session (tests/start-hybrid.test.sh).
set -uo pipefail

SESSION="${WORK_SESSION:-work}"
PRIMARY="$HOME/projects/optiroq-dev"          # standalone OptiroqAllma; treehouse pool source
ALLMA_CORE="$HOME/projects/allma-core"        # platform monorepo (optiroq nested in examples/optiroq)
FIRSTMATE="$HOME/tools/firstmate"
NPM_CACHE="$HOME/.npm-cache-shared"

[[ "${1:-}" == "kill" ]] && { tmux kill-session -t "$SESSION" 2>/dev/null && echo "session '$SESSION' killed" || echo "no session '$SESSION'"; exit 0; }

# Already running? Just re-attach (this is what makes it survive disconnects).
# Nothing below this point - leases, syncs, window builds - may run against a
# live session.
if tmux has-session -t "$SESSION" 2>/dev/null; then
    exec tmux attach -t "$SESSION"
fi

mkdir -p "$NPM_CACHE"

# Make treehouse/claude/gnhf/node resolve even if launched from a bare shell.
export PATH="$HOME/.local/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1

# Lease a worktree here (race-free) - pre-leased so each tab starts clean.
# TH_SKIP_SETUP: don't run the treehouse post_create dep-install synchronously here
# (it would block session startup); deps persist across reuse or install async.
lease_wt() { ( cd "$PRIMARY" && TH_SKIP_SETUP=1 treehouse get --lease --lease-holder "${1:-bridge}" 2>/dev/null | tail -1 ); }
GNHF_WT="$(lease_wt gnhf)"; [[ -d "$GNHF_WT" ]] || GNHF_WT="$PRIMARY"

# wt_has_unlanded <path>: does the worktree hold anything that could be unlanded
# work? Tolerates only the known setup drops that worktree-setup.sh and
# treehouse-post-create.sh place in every worktree (.env.e2e at the root,
# node_modules anywhere). Any other dirty or untracked path, any commit not
# already on origin/master, and any git error all count as possibly-unlanded.
wt_has_unlanded() {
    local p=$1 porcelain leftovers
    porcelain=$(git -C "$p" status --porcelain 2>/dev/null) || return 0
    leftovers=$(printf '%s\n' "$porcelain" \
        | grep -Ev '^\?\? (\.env\.e2e|([^ ]+/)?node_modules/)$' | grep -v '^$')
    [[ -n "$leftovers" ]] && return 0
    git -C "$p" merge-base --is-ancestor HEAD origin/master 2>/dev/null || return 0
    return 1
}

# sync_wt <path>: move the worktree to the latest origin/master when the sync
# contract in the header says it is safe; detached HEAD is the target shape.
# Returns 0 when the worktree ends up at the freshly fetched origin/master,
# 1 when it was left exactly as-is (possibly-unlanded work, or a git failure).
sync_wt() {
    local p=$1
    git -C "$p" fetch origin --quiet 2>/dev/null || return 1
    wt_has_unlanded "$p" && return 1
    git -C "$p" checkout --quiet --detach origin/master 2>/dev/null || return 1
}

# ── window: firstmate (coordinator) ─────────────────────────────────────────
tmux new-session -d -s "$SESSION" -n firstmate -c "$FIRSTMATE"
# CLAUDE_TMUX_WINDOW pins the tab name to 'firstmate' so the branch-naming
# SessionStart hook doesn't rename this coordinator tab to its git branch.
# --dangerously-skip-permissions: run the coordinator with full permissions
# (this is a personal dev box; firstmate's own crewmates + gnhf already do this).
# --remote-control firstmate: the coordinator is remotely controllable
# (claude.ai/code, mobile), same as the wt tabs below.
tmux send-keys -t "$SESSION:firstmate" "CLAUDE_TMUX_WINDOW=firstmate claude --dangerously-skip-permissions --remote-control firstmate" Enter

# ── windows: wt1 wt2 wt3 (three durable worktrees of the master project) ─────
# Static per-session worktrees of the master project (optiroq-dev). Each is DURABLY
# leased from the treehouse pool, so the pool never hands it out or prunes it until
# this session is killed. Each worktree is synced to the latest origin/master when
# safe (the sync contract in the header), then its tab launches a Claude Code
# session INSIDE it, running with:
#   --dangerously-skip-permissions   full permissions (this is a personal dev box)
#   --remote-control <wt>            a distinct, remotely-controllable session
#                                    (claude.ai/code, mobile) named for its tab
# CLAUDE_TMUX_WINDOW pins the tab name so the branch-naming SessionStart hook does
# not rename it. (This replaces the old Claude Squad tab.)
prev="firstmate"
for wt in wt1 wt2 wt3; do
    WT_PATH="$(lease_wt "$wt")"; [[ -d "$WT_PATH" ]] || WT_PATH="$PRIMARY"
    # Sync only a real leased worktree - never move the primary checkout's HEAD.
    note=""
    if [[ "$WT_PATH" != "$PRIMARY" ]]; then
        if sync_wt "$WT_PATH"; then
            note="echo '[$wt] synced: detached HEAD at latest origin/master'"
        else
            note="printf '%s\n' '##############################################################' '# WARNING: $wt was NOT synced to origin/master.' '# It may hold unlanded work (or git failed); left exactly' '# as-is. Inspect with: git status' '##############################################################'"
        fi
    fi
    tmux new-window -a -t "$SESSION:$prev" -n "$wt" -c "$WT_PATH"
    [[ -n "$note" ]] && tmux send-keys -t "$SESSION:$wt" "$note" Enter
    tmux send-keys -t "$SESSION:$wt" \
      "CLAUDE_TMUX_WINDOW=$wt claude --dangerously-skip-permissions --remote-control $wt" Enter
    prev="$wt"
done

# ── window: gnhf (own pre-leased worktree, ready to launch overnight tasks) ──
tmux new-window -a -t "$SESSION:$prev" -n gnhf -c "$GNHF_WT"
tmux send-keys -t "$SESSION:gnhf" \
  "clear && echo 'gnhf worktree: '\$(basename \$(git rev-parse --show-toplevel 2>/dev/null))' @ '\$(git branch --show-current 2>/dev/null) && echo 'Launch an overnight task, e.g.:' && echo '  gnhf \"<objective>\" --max-iterations 10 --max-tokens 5000000 --stop-when \"<done>\"'" Enter

prev="gnhf"

# ── window: allma-core (platform monorepo - work on @allma/* packages) ───────
if [ -d "$ALLMA_CORE" ]; then
    tmux new-window -a -t "$SESSION:$prev" -n allma-core -c "$ALLMA_CORE"
    tmux send-keys -t "$SESSION:allma-core" "CLAUDE_TMUX_WINDOW=allma-core claude --dangerously-skip-permissions" Enter
    prev="allma-core"
fi

# ── window: Midnight Commander ───────────────────────────────────────────────
tmux new-window -a -t "$SESSION:$prev" -n mc -c "$PRIMARY"
tmux send-keys -t "$SESSION:mc" "mc" Enter

tmux select-window -t "$SESSION:firstmate"

# Attach when run interactively; if there's no TTY (e.g. a smoke test), just report.
if [ -t 0 ] && [ -t 1 ]; then
    exec tmux attach -t "$SESSION"
else
    echo "session '$SESSION' created (no TTY - not attaching):"
    tmux list-windows -t "$SESSION"
fi
