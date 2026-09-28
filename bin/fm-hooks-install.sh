#!/usr/bin/env bash
# Ensure a project worktree has a mechanical quality floor: Claude Code hooks that
# enforce secret-scanning, lint, typecheck, and tests without an agent's cooperation.
# Hooks are the floor that cannot be talked out of it. The judgment layer on top of
# them is the crewmate's own independent review of its diff and firstmate's independent,
# direction-aware review of the diff before it reaches the user. The crewmate's review
# names no command by design; bin/fm-brief.sh's header owns why.
#
# This is a worktree utility for crewmates, not a supervision script, so it does not
# call fm-guard.sh, and firstmate never runs it against a project clone itself:
# hooks are project-intrinsic, so they are created inside a task worktree and
# committed through the project's normal delivery path, exactly like AGENTS.md
# (see bin/fm-ensure-agents-md.sh).
#
# NEVER CLOBBERS. A project that already hand-tuned its hooks keeps them; this
# script only reports. It installs the starter bundle solely when a project has no
# hook configuration at all.
#
# The starter bundle is deliberately conservative and auto-detected from
# package.json scripts. It is a floor to tune, not a finished policy.
#
# TWO MECHANISMS, NOT ONE. The bundle above is Claude Code hooks, which gate an
# AGENT's tool calls. This script also installs one GIT hook, post-commit, which
# fires on every commit however it was made. They are independent: a project that
# already has its own Claude hooks is left alone above but still gets the git
# hook, because the two never touch the same file.
#
# WHY A POST-COMMIT HOOK EXISTS AT ALL. Crews push once, at review-ready, at the
# end of a task, so every commit before that moment lives only on one disk. On
# 2026-08-27 a tmux failure took four crews' windows on one box and 221 commits
# across three repos existed on no remote ref, some five days old; they were
# recovered only because someone went looking. The hook closes that interval by
# mirroring HEAD to refs/heads/wip/<host>/<branch> on origin as each commit is
# made. It does NOT replace the review-ready push - it makes the wait for it
# survivable. It cannot help UNCOMMITTED work, which needs an autocommit nobody
# has asked for.
#
# IT MUST NOT WEAKEN THE PRE-PUSH GATE, AND DOES NOT. That gate is the Claude
# Code PreToolUse hook above, matching `git push` in an agent's Bash calls. A git
# hook's own push is not a Bash tool call, so it never reaches that gate - which
# is correct, because the only ref it can write is refs/heads/wip/*: a namespace
# nothing watches, never a PR source, never merged. The destination is built here
# and never taken from the caller. A crew's real push to its fm/<id> branch is
# still a Bash call and still gated, unchanged. The hook also does not pass
# --no-verify, so a project's own git pre-push hook still runs.
#
# That last choice has a price worth naming rather than discovering. On a project
# whose pre-push hook runs a test suite, the backup push runs it too, in the
# background, against mid-task state that is often deliberately broken - so the
# suite fails, the push no-ops, and the backup silently does not happen on
# exactly the projects that already take quality seriously. The install reports
# it out loud when it sees such a hook. Making the backup push skip it would fix
# that, and is a deliberate NON-decision here: bypassing a project's own gate is
# the captain's call, not this script's.
#
# THE GATE MUST REACH A VERDICT INSIDE ITS OWN BUDGET. A PreToolUse hook that
# outruns the timeout in settings.json is cancelled, and a cancelled hook does
# not block: the tool call carries on through the normal permission flow. The
# harness does not read the cancellation as approval - it simply never hears a
# verdict - but the push proceeds ungated either way, and that is what was
# measured on one project: seven pushes completed after their gate was cancelled
# without concluding. Raising the ceiling only moves it. So the emitted gate
# watches its own clock: GATE_BUDGET below is the deadline it enforces on
# itself, GATE_HOOK_TIMEOUT is what settings.json allows it, and the gap between
# them is what turns a slow check into a named refusal instead of a silent pass.
# The price is real and falls on the slowest pushes - a check against a cold
# cache is refused rather than allowed - and the remedy is the one crews already
# follow: run the check once by hand, which warms the cache, then push.
# Usage: fm-hooks-install.sh [repo-or-worktree-dir]
#        fm-hooks-install.sh --check [repo-or-worktree-dir]   report only, never write
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

CHECK_ONLY=0
POS=()
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --check) CHECK_ONLY=1 ;;
    *) POS+=("$a") ;;
  esac
done

DIR=${POS[0]:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)

SETTINGS="$DIR/.claude/settings.json"
HOOKDIR="$DIR/.claude/hooks"
MARKER='fm-quality'

# The no-fail-open contract described in the header, as numbers. They move
# together: GATE_BUDGET plus GATE_GRACE must stay below GATE_HOOK_TIMEOUT, or the
# gate is back to being cancelled mid-verdict. GATE_GRACE is what a check gets
# between the TERM at the deadline and the KILL that ends the argument.
# tests/fm-hooks-install.test.sh asserts the gap.
GATE_BUDGET=280
GATE_GRACE=5
GATE_HOOK_TIMEOUT=300

# --- The git post-commit backup hook. ---------------------------------------
#
# Runs BEFORE the Claude-hooks branch below, and returns rather than exiting, so
# a project that already has its own Claude hooks still gets this one: they are
# separate mechanisms writing separate files (see the header).
WIP_SENTINEL='fm-wip-push-generated'

# Where git will actually look for hooks. core.hooksPath, when set, REPLACES
# .git/hooks entirely, so writing to .git/hooks there would install a hook git
# never runs. Otherwise the common dir, not the worktree's own git dir: one
# install then covers the clone and every worktree of it.
resolve_hooks_dir() {
  local top common configured
  top=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || return 1
  configured=$(git -C "$DIR" config --get core.hooksPath 2>/dev/null || true)
  if [ -n "$configured" ]; then
    case "$configured" in
      /*) printf '%s\n' "$configured" ;;
      *)  printf '%s\n' "$top/$configured" ;;
    esac
    return 0
  fi
  common=$(git -C "$DIR" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) printf '%s\n' "$common/hooks" ;;
    *)  printf '%s\n' "$DIR/$common/hooks" ;;
  esac
}

install_wip_push_hook() {
  local hooks_dir target body top configured
  hooks_dir=$(resolve_hooks_dir) || {
    echo "wip-push: $DIR is not a git repository - skipped"
    return 0
  }
  target="$hooks_dir/post-commit"
  body="$hooks_dir/fm-wip-push"

  # core.hooksPath can point INSIDE the working tree, and commonly does: husky
  # sets it to .husky, a TRACKED directory. An untracked file written there is
  # dirt in every crew's worktree, which fm-teardown.sh reads as uncommitted work
  # and refuses on for the rest of the task, and which a crew may commit into the
  # project by accident. Skipping is the safe half - a hook inside the tree is
  # the project's own file to add, not firstmate's to plant.
  configured=$(git -C "$DIR" config --get core.hooksPath 2>/dev/null || true)
  if [ -n "$configured" ]; then
    top=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$top" ] && [ "${hooks_dir#"$top"/}" != "$hooks_dir" ] \
       && ! git -C "$DIR" check-ignore -q "$hooks_dir" 2>/dev/null; then
      echo "wip-push: core.hooksPath points inside the working tree ($hooks_dir) - skipped"
      echo "          (an untracked hook there reads as uncommitted work to teardown)"
      return 0
    fi
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    [ -e "$target" ] \
      && echo "wip-push: installed at $target" \
      || echo "HOOKS_MISSING: $DIR has no post-commit backup hook"
    return 0
  fi

  mkdir -p "$hooks_dir"

  # The body lives in its own file that git never invokes, so that a project
  # which already owns post-commit still has something to call. Only the tiny
  # dispatcher below is subject to the never-clobber check.
  cat > "$body" <<'WIPEOF'
#!/usr/bin/env bash
# fm-wip-push: mirror this commit to a backup ref on origin the moment it exists.
#
# Installed by firstmate's bin/fm-hooks-install.sh, which owns the contract and
# the rationale. In one line: crews push once, at the end of a task, so every
# commit before that lives on exactly one disk; this mirrors HEAD to
# refs/heads/wip/<host>/<branch>, a namespace nothing watches, so losing the
# machine stops meaning losing the work.
#
# THREE RULES, IN PRIORITY ORDER. post-commit runs AFTER the commit is already
# made, so nothing here may cost the commit anything:
#   1. Never FAIL the commit. Every path exits 0. No remote, no network, a
#      rejected push and a detached HEAD are all silent no-ops.
#   2. Never BLOCK the commit. The network work runs in a background subshell
#      with its own stdin and its output redirected. The redirect is the
#      load-bearing part: a backgrounded subshell inherits its caller's stdout,
#      so without it a caller reading `out=$(git commit ...)` keeps waiting on
#      the pipe long after git has exited.
#   3. Never SPEAK. A backup is not news; silence is the success case.
set -u

branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || exit 0
[ -n "$branch" ] || exit 0
git remote get-url origin >/dev/null 2>&1 || exit 0

host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)
host=${host//[^A-Za-z0-9._-]/-}
[ -n "$host" ] || host=unknown

common=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
common=$(cd "$common" 2>/dev/null && pwd -P) || exit 0

# A backup ref for the DEFAULT branch is pure noise: it is on the remote already,
# and the work at risk is on feature branches. origin/HEAD holds the answer in
# any repo made by `git clone`, but `git remote add` never sets it - and where it
# is missing, the default branch would both collect a pointless ref and be
# unprunable, because the prune below needs the same name as its ancestry base.
# So the background job resolves it once over the network and caches it here.
default=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
default=${default#origin/}
[ -n "$default" ] || default=$(cat "$common/fm-wip-default" 2>/dev/null || true)
case "$default" in *[!A-Za-z0-9._/-]*) default= ;; esac
case "$branch" in main|master|trunk) exit 0 ;; esac
if [ -n "$default" ] && [ "$branch" = "$default" ]; then
  exit 0
fi

FM_WIP_TIMEOUT=${FM_WIP_TIMEOUT:-120}
FM_WIP_PRUNE_INTERVAL=${FM_WIP_PRUNE_INTERVAL:-86400}

# Bound the network calls where timeout(1) exists. Nothing waits on this job, so
# its absence costs nothing a hung push would not have cost anyway.
net() {
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=10s "${FM_WIP_TIMEOUT}s" "$@"
  else
    "$@"
  fi
}

(
  # wip/<host>/<branch>, not wip/<branch>-<host>. The host is a PATH COMPONENT so
  # the split is unambiguous: host names cannot contain "/" (sanitized above) but
  # branch names routinely do, so a "-" joiner makes wip/f/x-a from host "b"
  # indistinguishable from wip/f/x from host "a-b", and makes the prune filter
  # below match host "box" against another machine's "bigbox".
  dst="refs/heads/wip/$host/$branch"
  git check-ref-format "$dst" || exit 0

  # Two commits made inside one push's latency start two force-pushes at once,
  # and nothing orders their completion: the older one landing last would leave
  # the backup pointing at the OLDER commit - losing exactly the newest work
  # this hook exists to save. So serialize per-repo, and push the branch rather
  # than HEAD, because git resolves the source ref when the push actually runs:
  # whoever holds the lock last therefore pushes the newest tip either way.
  # Without flock(1) the pushes stay unordered and that narrow race remains.
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$common/fm-wip-push.lock" || exit 0
    flock -w "$FM_WIP_TIMEOUT" 9 || exit 0
  fi

  # Forced, because the ref is a MIRROR of the local branch and not a history.
  # Without --force the first amend or rebase makes every later backup
  # non-fast-forward, and the hook fails silently from then on - far worse than
  # superseding a backup whose commits are still in the local reflog.
  #
  # No --no-verify: a project's own git pre-push hook still runs.
  net git push --quiet --force origin "refs/heads/$branch:$dst" || exit 0

  # --- Prune: merged-only, at most once a day. ------------------------------
  #
  # A wip ref dies exactly when its tip is already an ancestor of the remote
  # default branch: the work landed, so the backup is noise. It is NEVER deleted
  # by age. An unlanded backup is precisely the work this hook exists to protect,
  # and a timer would delete the only copy of it. Growth is therefore bounded by
  # unlanded branches rather than by commits, and a wip ref that persists is a
  # signal worth keeping.
  stamp="$common/fm-wip-prune.stamp"
  last=$(cat "$stamp" 2>/dev/null || true)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  now=$(date +%s)
  # A stamp from the FUTURE - one bad container clock, a VM resumed from a
  # snapshot, a single NTP step - would otherwise disable pruning until real time
  # caught up with it, which is to say permanently.
  [ "$last" -le "$now" ] || last=0
  [ "$(( now - last ))" -ge "$FM_WIP_PRUNE_INTERVAL" ] || exit 0
  printf '%s\n' "$now" > "$stamp" 2>/dev/null || exit 0

  # Resolve and cache the default branch when origin/HEAD did not answer. Kept
  # inside the sweep so it costs one extra round trip a day, not one per commit.
  if [ -z "$default" ]; then
    default=$(net git ls-remote --symref origin HEAD 2>/dev/null \
      | awk '$1 == "ref:" { sub(/^refs\/heads\//, "", $2); print $2; exit }')
    case "$default" in
      ''|*[!A-Za-z0-9._/-]*) default= ;;
      *) printf '%s\n' "$default" > "$common/fm-wip-default" 2>/dev/null || true ;;
    esac
  fi

  # The ancestry test needs a LOCAL object, so it reads the remote-tracking ref
  # rather than fetching: a background fetch would move origin/<default> under a
  # crew mid-task. A stale tracking ref only means pruning less this sweep.
  base=
  for candidate in "$default" main master; do
    [ -n "$candidate" ] || continue
    if git rev-parse --quiet --verify "refs/remotes/origin/$candidate^{commit}" >/dev/null 2>&1; then
      base="refs/remotes/origin/$candidate"
      break
    fi
  done
  [ -n "$base" ] || exit 0

  doomed=()
  while read -r sha ref; do
    # Another host's backup is not ours to delete.
    case "$ref" in "refs/heads/wip/$host/"*) ;; *) continue ;; esac
    # An object we do not have locally fails this and is kept, not guessed at.
    git merge-base --is-ancestor "$sha" "$base" 2>/dev/null || continue
    doomed+=("$ref")
    [ "${#doomed[@]}" -lt 100 ] || break
  done < <(net git ls-remote --quiet --heads origin 2>/dev/null)

  [ "${#doomed[@]}" -gt 0 ] || exit 0
  net git push --quiet origin --delete "${doomed[@]}" || exit 0
) </dev/null >/dev/null 2>&1 &

exit 0
WIPEOF
  chmod +x "$body"

  # NEVER CLOBBERS, exactly as the bundle below does not. A project's own
  # post-commit carries knowledge this generic hook does not, and chaining into
  # it automatically would be a guess at its contract.
  #
  # The test is for the GENERATED sentinel, not for the string "fm-wip-push". A
  # project that takes the advice below writes a post-commit that names
  # fm-wip-push, and a substring test would then read that wrapper as ours and
  # overwrite it - deleting project logic, silently, on the next task, since
  # crews run this script every time.
  if [ -e "$target" ] && ! grep -q "$WIP_SENTINEL" "$target" 2>/dev/null; then
    echo "wip-push: $target already exists and is not ours - left untouched"
    echo "          (to get commit backups too, run $body from it)"
    return 0
  fi

  cat > "$target" <<WIPDISPATCH
#!/usr/bin/env bash
# $WIP_SENTINEL - firstmate wrote this file; bin/fm-hooks-install.sh owns it.
# The work is in fm-wip-push beside it, so a project that wants its own
# post-commit can keep this file's job by calling that script instead.
h="\$(dirname "\$0")/fm-wip-push"
[ -x "\$h" ] && exec "\$h"
exit 0
WIPDISPATCH
  chmod +x "$target"
  echo "wip-push: installed the post-commit backup hook at $target"
  echo "          every commit on a feature branch mirrors to origin refs/heads/wip/<host>/<branch>"
  echo "          (CI on that project should ignore wip/** or it runs a job per crew commit)"

  # Said out loud because the alternative is a feature that silently does
  # nothing on exactly the projects that already take quality seriously.
  if [ -x "$hooks_dir/pre-push" ]; then
    echo "wip-push: this project has its own git pre-push hook, which the backup push"
    echo "          also runs - a backup is skipped whenever that hook fails"
  fi
}

install_wip_push_hook

# Already has hooks of any kind? Report and stop. This is the common case for a
# project the user already tuned by hand, and clobbering it would be a
# regression dressed up as an install.
if [ -f "$SETTINGS" ] && grep -q '"hooks"' "$SETTINGS" 2>/dev/null; then
  if grep -q "$MARKER" "$SETTINGS" 2>/dev/null; then
    echo "hooks: firstmate starter bundle already installed in $SETTINGS"
  else
    echo "hooks: project already has its own hooks in $SETTINGS - left untouched"
  fi
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "HOOKS_MISSING: $DIR has no Claude Code quality hooks"
  exit 0
fi

# Auto-detect the project's own commands rather than inventing them. An undetected
# command becomes a no-op rather than a wrong command that blocks every push.
detect_script() {
  # $1: npm script name. Prints the run command, or nothing.
  [ -f "$DIR/package.json" ] || return 0
  if command -v node >/dev/null 2>&1; then
    node -e '
      const fs = require("fs");
      try {
        const p = JSON.parse(fs.readFileSync(process.argv[1] + "/package.json", "utf8"));
        if (p.scripts && p.scripts[process.argv[2]]) console.log("npm run " + process.argv[2]);
      } catch {}
    ' "$DIR" "$1" 2>/dev/null
  fi
}

TEST_CMD=$(detect_script test)
TYPECHECK_CMD=$(detect_script typecheck)
LINT_CMD=$(detect_script lint)

mkdir -p "$HOOKDIR"

# --- Secret scan: universal, no project knowledge needed. -------------------
cat > "$HOOKDIR/fm-quality-secret-scan.sh" <<'EOF'
#!/usr/bin/env bash
# fm-quality: block secrets and env files from being staged.
# Fires on git commit / git add. Exit 2 blocks the tool call.
set -eu
INPUT=$(cat)
if command -v jq >/dev/null 2>&1; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
else
  COMMAND=$(printf '%s' "$INPUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).tool_input?.command??"")}catch{console.log("")}})')
fi
echo "$COMMAND" | grep -qE '^git (commit|add)' || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}"

STAGED=$(git diff --cached --name-only 2>/dev/null || true)
if printf '%s' "$STAGED" | grep -qE '(^|/)\.env(\.|$)'; then
  echo "BLOCKED: a .env file is staged. Never commit secrets." >&2
  exit 2
fi
if printf '%s' "$STAGED" | grep -qE '\.(pem|key|p12|pfx)$'; then
  echo "BLOCKED: a private key file is staged." >&2
  exit 2
fi
# Match credential VALUES on added lines only, not bare mentions of the variable
# name and not GitHub Actions ${{ secrets.* }} references, which are names.
CRED_RE='AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AWS_SECRET_ACCESS_KEY[[:space:]]*[:=][[:space:]"'"'"']*[A-Za-z0-9/+]{16,}'
if git diff --cached -U0 2>/dev/null \
    | grep -E '^\+[^+]' \
    | grep -vE '\$\{\{[[:space:]]*secrets\.' \
    | grep -qE "$CRED_RE"; then
  echo "BLOCKED: possible credentials detected in staged changes." >&2
  exit 2
fi
exit 0
EOF

# --- Pre-push gate: the mechanical floor before anything leaves the machine. ---
{
  cat <<'EOF'
#!/usr/bin/env bash
# fm-quality: run the project's own checks before any push. Exit 2 blocks the push.
set -eu
INPUT=$(cat)
if command -v jq >/dev/null 2>&1; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
else
  COMMAND=$(printf '%s' "$INPUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).tool_input?.command??"")}catch{console.log("")}})')
fi
echo "$COMMAND" | grep -qE '^git push' || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}"

if [ -n "$(git status --porcelain)" ]; then
  echo "BLOCKED: uncommitted changes in the tree. Commit or stash before pushing." >&2
  exit 2
fi
EOF
  if [ -n "$TYPECHECK_CMD" ] || [ -n "$TEST_CMD" ]; then
    # The self-imposed deadline. A check that outruns it is refused BY NAME,
    # because the alternative - being cancelled by the harness - leaves the push
    # unblocked with no verdict at all. The watchdog is written in bash rather
    # than delegated to timeout(1): where that binary is absent the hook would
    # exit 127, and only exit 2 blocks a tool call, so the missing binary would
    # itself be a silent fail-open.
    printf '\nGATE_BUDGET=%s\nGATE_GRACE=%s\n' "$GATE_BUDGET" "$GATE_GRACE"
    cat <<'EOF'

gate_refuse() {
  echo "BLOCKED: $1" >&2
  echo "The push is refused rather than allowed unchecked. Run the checks by hand once - that also warms the build cache - then push." >&2
  exit 2
}

# Runs one check under the remaining budget. SECONDS is the whole hook's age, so
# several checks share one deadline instead of each getting a fresh one.
#
# Both jobs are started under `set -m` so each leads its own process group, and
# each is signalled by group. Signalling the check alone is not enough: `npm run
# test` is a shell that spawns the real runner, and a surviving grandchild keeps
# holding this hook's stdout after the hook itself is done.
#
# TERM then KILL, because the budget has to be a deadline and not a request. A
# check that traps TERM and cleans up slowly, or ignores it, or is stopped
# rather than killed, would otherwise keep this hook running past the harness
# timeout - which cancels the hook and leaves the push unblocked, the exact
# failure the budget exists to prevent. GATE_GRACE is the only slack it gets.
gate_run() {
  local label=$1 left status check_pid watchdog_pid
  shift
  left=$(( GATE_BUDGET - SECONDS ))
  [ "$left" -gt 0 ] \
    || gate_refuse "the gate's ${GATE_BUDGET}s budget was spent before $label could start."

  set -m
  "$@" &
  check_pid=$!
  ( sleep "$left"
    kill -TERM -- -"$check_pid"
    sleep "$GATE_GRACE"
    kill -KILL -- -"$check_pid" ) >/dev/null 2>&1 &
  watchdog_pid=$!
  set +m

  status=0
  wait "$check_pid" || status=$?
  kill -TERM -- -"$watchdog_pid" >/dev/null 2>&1 || true

  # Deadline before status: a check killed at the deadline may still have exited
  # 0 on its way out, and that is not a verdict.
  [ "$SECONDS" -lt "$GATE_BUDGET" ] \
    || gate_refuse "$label did not finish within the gate's ${GATE_BUDGET}s budget."
  if [ "$status" -ne 0 ]; then
    echo "BLOCKED: $label failed." >&2
    exit 2
  fi
}
EOF
  fi
  if [ -n "$TYPECHECK_CMD" ]; then
    printf '\ngate_run typecheck %s\n' "$TYPECHECK_CMD"
  fi
  if [ -n "$TEST_CMD" ]; then
    printf '\ngate_run tests %s\n' "$TEST_CMD"
  fi
  if [ -z "$TYPECHECK_CMD" ] && [ -z "$TEST_CMD" ]; then
    printf '\n# No test or typecheck script was detected at install time.\n# Add the project'"'"'s real check commands here - an empty gate is not a gate.\n'
  fi
  printf '\nexit 0\n'
} > "$HOOKDIR/fm-quality-pre-push.sh"

# --- Post-edit lint: keep the tree clean as it is written. -------------------
if [ -n "$LINT_CMD" ]; then
  cat > "$HOOKDIR/fm-quality-post-edit.sh" <<'EOF'
#!/usr/bin/env bash
# fm-quality: lint after every Edit/Write. Never blocks; best-effort only.
set -eu
cd "${CLAUDE_PROJECT_DIR:-.}"
npx eslint --fix . >/dev/null 2>&1 || true
exit 0
EOF
fi

chmod +x "$HOOKDIR"/fm-quality-*.sh

# --- settings.json ----------------------------------------------------------
POST_BLOCK=""
if [ -n "$LINT_CMD" ]; then
  POST_BLOCK=$(cat <<'EOF'
,
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/fm-quality-post-edit.sh",
            "timeout": 30,
            "statusMessage": "Linting..."
          }
        ]
      }
    ]
EOF
)
fi

mkdir -p "$DIR/.claude"
cat > "$SETTINGS" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "\${CLAUDE_PROJECT_DIR}/.claude/hooks/fm-quality-secret-scan.sh",
            "timeout": 30,
            "statusMessage": "Scanning for secrets..."
          },
          {
            "type": "command",
            "command": "\${CLAUDE_PROJECT_DIR}/.claude/hooks/fm-quality-pre-push.sh",
            "timeout": $GATE_HOOK_TIMEOUT,
            "statusMessage": "Running pre-push checks..."
          }
        ]
      }
    ]$POST_BLOCK
  }
}
EOF

echo "hooks: installed the fm-quality starter bundle in $SETTINGS"
[ -n "$TEST_CMD" ]      && echo "  pre-push test:      $TEST_CMD"
[ -n "$TYPECHECK_CMD" ] && echo "  pre-push typecheck: $TYPECHECK_CMD"
[ -n "$LINT_CMD" ]      && echo "  post-edit lint:     detected"
if [ -n "$TEST_CMD" ] || [ -n "$TYPECHECK_CMD" ]; then
  echo "  pre-push budget:    ${GATE_BUDGET}s for all checks together, under the hook's ${GATE_HOOK_TIMEOUT}s timeout"
  echo "                      a check that overruns REFUSES the push - run it once by hand to warm caches, then push"
fi
if [ -z "$TEST_CMD" ] && [ -z "$TYPECHECK_CMD" ]; then
  echo "  WARNING: no test or typecheck script detected - the pre-push gate is empty until you fill it in"
fi
exit 0
