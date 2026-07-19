#!/usr/bin/env bash
# Read, scaffold, and validate a project's direction: the business vision and the
# quality, infrastructure, and architecture direction that every change to that
# project must move with.
# Direction files live at data/directions/<project>.md under the active firstmate
# home. They are firstmate-private (data/ is gitignored), because business vision
# and product strategy are the user's, not the project's.
# Usage: fm-direction.sh path  <project>   print the direction file's path
#        fm-direction.sh show  <project>   print the file, or nothing when absent
#        fm-direction.sh brief <project>   print the brief-ready "# Direction" block
#        fm-direction.sh init  <project>   scaffold a template (refuses to overwrite)
#        fm-direction.sh check [<project>] validate; exits non-zero on a hard problem
#        fm-direction.sh list             list every project and whether it has one
#        fm-direction.sh alpha-deploy <project>
#              print the project's Alpha deploy command, taken from an
#              "Alpha deploy: <command>" line under "## Infrastructure direction".
#              Exits non-zero with no output when the project has no direction or no
#              such line, so a mission's Alpha gate can pause and ask rather than
#              guess a deploy. Alpha only - production promotion is never automated.
#        fm-direction.sh add-decision <project> <text>
#              append a dated one-liner under "## Standing decisions", drop the
#              scaffold placeholder if still present, then validate. This is the
#              reliable, word-cap-checked write path for a resolved decision so the
#              automatic capture flow never hand-edits the capped file. It exits
#              non-zero (after writing) if the file is now over the hard word cap,
#              so the caller knows to curate; an axis-level shift (a change to the
#              business/architecture/infrastructure/quality direction itself) is a
#              judgment rewrite of that axis, not an add-decision append.
# Why a word cap: the brief block is injected verbatim into EVERY brief for that
# project, ship and scout alike, so it is paid for on every dispatch. A direction
# that grows into a design doc stops being read. check warns past
# FM_DIRECTION_SOFT_WORDS and fails past FM_DIRECTION_HARD_WORDS.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DIRDIR="$DATA/directions"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

SOFT_WORDS=${FM_DIRECTION_SOFT_WORDS:-450}
HARD_WORDS=${FM_DIRECTION_HARD_WORDS:-900}

# The five headings a direction must carry. The first four are the user's axes;
# Standing decisions accumulates the resolved answers so a decision made once is
# never re-litigated by the next crewmate.
REQUIRED_HEADINGS=(
  '## Business vision'
  '## Architecture direction'
  '## Infrastructure direction'
  '## Quality direction'
  '## Standing decisions'
)

die() { echo "error: $*" >&2; exit 1; }

file_for() { printf '%s\n' "$DIRDIR/$1.md"; }

cmd_path() { file_for "$1"; }

cmd_show() {
  f=$(file_for "$1")
  [ -f "$f" ] || return 0
  cat "$f"
}

# The block pasted into a crewmate brief. When a project has no direction yet, say
# so explicitly rather than printing nothing: a crewmate that sees an empty section
# cannot tell "no direction exists" from "the scaffold broke".
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped `needs-decision:` snippets must reach the reading agent verbatim, not expand at scaffold time.
cmd_brief() {
  project=$1
  f=$(file_for "$project")
  echo '# Direction'
  if [ ! -f "$f" ]; then
    echo "No direction is on file for \`$project\` yet."
    echo 'Use your best judgment, and if the task turns on a question of product intent, architecture, or quality posture that you cannot answer from the codebase, escalate it with `needs-decision:` rather than guessing.'
    return 0
  fi
  echo "This is the standing direction for \`$project\`. It is the user's, not yours to revise."
  echo
  # Drop the file's own H1 title; the brief supplies the heading.
  sed '/^# /d' "$f"
  echo
  echo '**This applies to every change, however small.**'
  echo 'Before you report done, state in one line how your change honors the architecture, infrastructure, and quality direction above.'
  echo 'If the task as specified would move against the direction, do NOT quietly implement it: append `needs-decision: direction conflict - {what conflicts, and the options}` and stop.'
  echo 'A bug fix that patches a symptom in a way the architecture direction is trying to eliminate is exactly such a conflict.'
}

# Extract the project's Alpha deploy command from an "Alpha deploy: <command>" line
# under "## Infrastructure direction". Prints the command, or exits 1 with no output
# when the direction or the line is absent, so a mission's Alpha gate treats a
# missing deploy as "pause and ask", never as a silent no-op.
cmd_alpha_deploy() {
  project=$1
  f=$(file_for "$project")
  [ -f "$f" ] || return 1
  cmd=$(awk '
    /^## Infrastructure direction/ { ininfra = 1; next }
    ininfra && /^## / { ininfra = 0 }
    ininfra && /^Alpha deploy:/ {
      sub(/^Alpha deploy:[[:space:]]*/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$f")
  [ -n "$cmd" ] || return 1
  printf '%s\n' "$cmd"
}

cmd_init() {
  project=$1
  f=$(file_for "$project")
  [ -e "$f" ] && die "$f already exists"
  mkdir -p "$DIRDIR"
  cat > "$f" <<EOF
# $project - Direction

## Business vision
{What this product is for, who it serves, and what winning looks like. Two or three lines.}

## Architecture direction
{The target shape. The invariants that must hold. What we are deliberately moving toward, and what we are moving away from.}

## Infrastructure direction
{Deploy, ops, and cost posture. What runs where, and what we refuse to run. For mission-mode Alpha verification, add a line "Alpha deploy: <command>" here.}

## Quality direction
{Test posture. What "good" means here. The non-negotiables, and the debt we knowingly accept.}

## Standing decisions
{Dated one-liners. Grown over time from the user's answers, so a decision made once is never re-litigated.}
EOF
  echo "scaffolded: $f (replace every {...} placeholder)"
}

# Validate one file. Prints diagnostics; returns 1 on a hard failure.
check_one() {
  project=$1
  f=$(file_for "$project")
  rc=0
  if [ ! -f "$f" ]; then
    echo "DIRECTION_MISSING: $project (no data/directions/$project.md)"
    return 0
  fi

  for h in "${REQUIRED_HEADINGS[@]}"; do
    if ! grep -qxF "$h" "$f"; then
      echo "DIRECTION_INVALID: $project is missing the heading '$h'"
      rc=1
    fi
  done

  if grep -q '{' "$f"; then
    echo "DIRECTION_STUB: $project still has unfilled {...} placeholders"
  fi

  words=$(wc -w < "$f" | tr -d ' ')
  if [ "$words" -gt "$HARD_WORDS" ]; then
    echo "DIRECTION_TOO_LONG: $project is $words words (hard cap $HARD_WORDS); it is injected into every brief - cut it down"
    rc=1
  elif [ "$words" -gt "$SOFT_WORDS" ]; then
    echo "DIRECTION_LONG: $project is $words words (soft cap $SOFT_WORDS); it is injected into every brief - consider trimming"
  fi

  return "$rc"
}

cmd_check() {
  rc=0
  if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    check_one "$1" || rc=1
    return "$rc"
  fi
  for p in $(list_projects); do
    check_one "$p" || rc=1
  done
  return "$rc"
}

list_projects() {
  [ -d "$PROJECTS" ] || return 0
  find "$PROJECTS" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort
}

cmd_list() {
  for p in $(list_projects); do
    f=$(file_for "$p")
    if [ -f "$f" ]; then
      words=$(wc -w < "$f" | tr -d ' ')
      printf '%s\tdirection (%s words)\n' "$p" "$words"
    else
      printf '%s\tNONE\n' "$p"
    fi
  done
}

# Append a dated one-liner under "## Standing decisions". Newest-first (right
# after the heading), so the freshest resolved decision is what a reader sees
# first. A fresh scaffold's "{...}" placeholder line is dropped on the first real
# decision. The date is date +%F, overridable with FM_DIRECTION_DATE for tests.
cmd_add_decision() {
  project=$1; shift
  text="$*"
  [ -n "$text" ] || die "add-decision needs decision text"
  f=$(file_for "$project")
  [ -f "$f" ] || die "no direction on file for '$project' (run: fm-direction.sh init '$project' and author it first)"
  grep -qxF '## Standing decisions' "$f" \
    || die "direction for '$project' has no '## Standing decisions' heading"
  # Collapse any newlines the caller passed: a standing decision is one line.
  text=$(printf '%s' "$text" | tr '\n' ' ')
  today=${FM_DIRECTION_DATE:-$(date +%F)}
  line="- $today $text"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-direction.XXXXXX") || die "mktemp failed"
  awk -v new="$line" '
    BEGIN { armed = 0 }
    {
      if ($0 == "## Standing decisions") { print; print new; armed = 1; next }
      if (armed == 1) {
        if ($0 ~ /^[[:space:]]*$/) { print; next }        # keep blank lines, keep scanning
        armed = 0
        if ($0 ~ /^[[:space:]]*\{.*\}[[:space:]]*$/) next  # drop the scaffold placeholder
      }
      print
    }
  ' "$f" > "$tmp" || { rm -f "$tmp"; die "failed to rewrite $f"; }
  mv -f "$tmp" "$f"
  echo "recorded: $line"
  # Validate after writing. A soft-cap warning is informational; a hard-cap
  # failure returns non-zero so the caller curates, but the decision is kept.
  check_one "$project" || return 1
  return 0
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac

ACTION=$1
shift || true

case "$ACTION" in
  path)  [ "$#" -ge 1 ] || die "path needs a project"; cmd_path "$1" ;;
  show)  [ "$#" -ge 1 ] || die "show needs a project"; cmd_show "$1" ;;
  brief) [ "$#" -ge 1 ] || die "brief needs a project"; cmd_brief "$1" ;;
  init)  [ "$#" -ge 1 ] || die "init needs a project"; cmd_init "$1" ;;
  check) cmd_check "${1:-}" ;;
  list)  cmd_list ;;
  add-decision) [ "$#" -ge 2 ] || die "add-decision needs a project and text"; cmd_add_decision "$@" ;;
  alpha-deploy) [ "$#" -ge 1 ] || die "alpha-deploy needs a project"; cmd_alpha_deploy "$1" ;;
  *)     die "unknown action '$ACTION' (see --help)" ;;
esac
