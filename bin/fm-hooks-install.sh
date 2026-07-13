#!/usr/bin/env bash
# Ensure a project worktree has a mechanical quality floor: Claude Code hooks that
# enforce secret-scanning, lint, typecheck, and tests without an agent's cooperation.
# Hooks are the floor that cannot be talked out of it. The judgment layer on top of
# them is the crewmate's own /code-review pass and firstmate's independent,
# direction-aware review of the diff before it reaches the captain.
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

# Already has hooks of any kind? Report and stop. This is the common case for a
# project the captain already tuned by hand, and clobbering it would be a
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
  if [ -n "$TYPECHECK_CMD" ]; then
    printf '\nif ! %s; then\n  echo "BLOCKED: typecheck failed." >&2\n  exit 2\nfi\n' "$TYPECHECK_CMD"
  fi
  if [ -n "$TEST_CMD" ]; then
    printf '\nif ! %s; then\n  echo "BLOCKED: tests failed." >&2\n  exit 2\nfi\n' "$TEST_CMD"
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
            "timeout": 300,
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
if [ -z "$TEST_CMD" ] && [ -z "$TYPECHECK_CMD" ]; then
  echo "  WARNING: no test or typecheck script detected - the pre-push gate is empty until you fill it in"
fi
exit 0
