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
# THE GATE MUST REACH A VERDICT INSIDE ITS OWN BUDGET. Claude Code cancels a
# hook that outruns the timeout in settings.json and then runs the tool anyway,
# so an overrun is read as consent: measured on one project, seven pushes
# completed after their gate was cancelled without concluding. Raising the
# ceiling only moves it. So the emitted gate watches its own clock: GATE_BUDGET
# below is the deadline it enforces on itself, GATE_HOOK_TIMEOUT is what
# settings.json allows it, and the gap between them is what turns a slow check
# into a named refusal instead of a silent pass. The price is real and falls on
# the slowest pushes - a check against a cold cache is refused rather than
# allowed - and the remedy is the one crews already follow: run the check once
# by hand, which warms the cache, then push.
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
    # because the alternative - being cancelled by the harness - lets the push
    # through with no verdict at all. The watchdog is written in bash rather
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
# timeout - which cancels the hook and lets the push through, the exact failure
# the budget exists to prevent. GATE_GRACE is the only slack it gets.
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
