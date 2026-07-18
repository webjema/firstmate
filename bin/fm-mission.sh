#!/usr/bin/env bash
# Create, read, and validate a mission: the whole-goal container that mission mode
# decomposes into an ordered task DAG, dispatches, reviews, merges, and ships.
# Mission files live at data/missions/<id>.md under the active firstmate home. They
# are firstmate-private (data/ is gitignored), because a goal and its acceptance
# criteria are the user's, not the project's.
#
# This script owns the mission-file contract. Firstmate never hand-edits a mission
# file; every write goes through here, the same way a direction goes through
# bin/fm-direction.sh. The `/mission` skill is the conversational entry point that
# drives this engine.
#
# A mission carries five sections:
#   Goal               the end goal, in the user's words
#   Acceptance criteria the whole-goal definition of done, drafted by the planning
#                      pass and confirmed by the user; this is what the end-of-mission
#                      Alpha integration-verification gate checks against
#   Task DAG           the membership roster of the mission's tasks, one per line,
#                      with their blocked-by edges as a readable snapshot. tasks-axi
#                      is authoritative for the edges and each task's live state; this
#                      section is the mission's own record of WHICH tasks are its own,
#                      so a recovered firstmate can reconstruct the mission from disk.
#   Autonomy envelope  the single outer tripwire (max tasks / spend / wall-clock) that
#                      catches a runaway plan; a trip pauses the mission and escalates
#   Completion rollup  a live status line, updated as the mission advances
#
# Usage: fm-mission.sh new "<goal>" [--repo <name>] [--id <id>]
#              [--max-tasks <n>] [--max-spend <usd>] [--max-hours <n>]
#            mint a mission id (a kebab slug from the goal plus a random suffix, like
#            a task id), scaffold data/missions/<id>.md with the goal and envelope,
#            and print the id and path. Refuses to overwrite an existing mission.
#        fm-mission.sh path <id>            print the mission file's path
#        fm-mission.sh show <id>            print the file, or nothing when absent
#        fm-mission.sh list                 list every mission and its task count
#        fm-mission.sh check [<id>]         validate; exits non-zero on a hard problem
#        fm-mission.sh set-criteria <id> [--file <path>]
#            replace the Acceptance criteria section body from <path> or stdin. This
#            is the user-confirmed write path the planning pass uses once the drafted
#            criteria are approved; it drops the scaffold placeholder.
#        fm-mission.sh add-task <id> <task-id> [--blocked-by <id>]...
#            record a task as a member of the mission's DAG, with its blocked-by
#            edges as a readable snapshot; drops the scaffold placeholder. Idempotent
#            per task-id: re-adding a task-id rewrites that one line.
#        fm-mission.sh tasks <id>          print the mission's member task-ids, one
#            per line (the DAG roster). The dispatcher intersects this with the
#            `tasks-axi ready` frontier to decide what to spawn next; this script
#            deliberately does not read tasks-axi state itself.
#        fm-mission.sh set-rollup <id> [--file <path>]
#            replace the Completion rollup section body from <path> or stdin. The
#            live rollup (tasks landed / total) is computed by the mission
#            supervisor from tasks-axi state and written here, so the file owner
#            stays the sole writer.
#
# Envelope defaults are conservative so an early trip is cheap; they are per-mission
# overridable at `new` and env-overridable (FM_MISSION_MAX_TASKS, FM_MISSION_MAX_SPEND,
# FM_MISSION_MAX_HOURS). See docs/configuration.md.
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
MISSIONDIR="$DATA/missions"

# Conservative defaults: an early trip is a cheap confirm-and-continue, a runaway
# plan is caught fast, and a genuinely big mission just gets a higher envelope at
# `new`. The direction axes, the review panel, and the tests are the real
# guardrails; this envelope only catches a runaway plan.
DEF_MAX_TASKS=${FM_MISSION_MAX_TASKS:-15}
DEF_MAX_SPEND=${FM_MISSION_MAX_SPEND:-50}
DEF_MAX_HOURS=${FM_MISSION_MAX_HOURS:-12}

# The six headings a mission must carry.
REQUIRED_HEADINGS=(
  '## Goal'
  '## Acceptance criteria'
  '## Task DAG'
  '## Autonomy envelope'
  '## Completion rollup'
)

# The three envelope keys, each a positive integer.
ENVELOPE_KEYS=(max-tasks max-spend-usd max-wallclock-hours)

die() { echo "error: $*" >&2; exit 1; }

file_for() { printf '%s\n' "$MISSIONDIR/$1.md"; }

# Slugify a goal into a short kebab stem: lowercase, non-alnum to dash, collapse
# and trim dashes, keep the first few words, cap the length. Empty input yields
# "mission" so an id is always well-formed.
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' \
    | sed -E 's/-+/-/g; s/^-//; s/-$//' \
    | cut -c1-32 \
    | sed -E 's/-$//'
}

# A two-char alnum suffix, like a task id's. Overridable for deterministic tests.
mint_suffix() {
  if [ -n "${FM_MISSION_SUFFIX:-}" ]; then
    printf '%s\n' "$FM_MISSION_SUFFIX"
    return 0
  fi
  LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c2
  echo
}

cmd_path() { file_for "$1"; }

cmd_show() {
  f=$(file_for "$1")
  [ -f "$f" ] || return 0
  cat "$f"
}

cmd_new() {
  goal="" repo="" id="" max_tasks="$DEF_MAX_TASKS" max_spend="$DEF_MAX_SPEND" max_hours="$DEF_MAX_HOURS"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)       repo=${2:?--repo needs a value}; shift 2 ;;
      --id)         id=${2:?--id needs a value}; shift 2 ;;
      --max-tasks)  max_tasks=${2:?--max-tasks needs a value}; shift 2 ;;
      --max-spend)  max_spend=${2:?--max-spend needs a value}; shift 2 ;;
      --max-hours)  max_hours=${2:?--max-hours needs a value}; shift 2 ;;
      --*)          die "unknown flag '$1' (see --help)" ;;
      *)            [ -z "$goal" ] || die "unexpected argument '$1'"; goal=$1; shift ;;
    esac
  done
  [ -n "$goal" ] || die "new needs a goal: fm-mission.sh new \"<goal>\""
  for kv in "max-tasks=$max_tasks" "max-spend=$max_spend" "max-hours=$max_hours"; do
    v=${kv#*=}
    case "$v" in
      ''|*[!0-9]*) die "${kv%%=*} must be a positive integer, got '$v'" ;;
    esac
    [ "$v" -gt 0 ] || die "${kv%%=*} must be greater than zero"
  done
  if [ -z "$id" ]; then
    stem=$(slugify "$goal")
    [ -n "$stem" ] || stem=mission
    id="$stem-$(mint_suffix)"
  fi
  f=$(file_for "$id")
  [ -e "$f" ] && die "$f already exists (mission id '$id' is taken)"
  mkdir -p "$MISSIONDIR"
  repo_line="(no project resolved yet)"
  [ -n "$repo" ] && repo_line="$repo"
  cat > "$f" <<EOF
# $id - Mission

- project: $repo_line

## Goal
$goal

## Acceptance criteria
{Drafted by the planning pass from the goal, confirmed by the user. Testable, one per line. This is what the end-of-mission Alpha integration-verification gate checks against.}

## Task DAG
{The mission's own tasks, one per line as \`- <task-id> [blocked-by: <id>, <id>]\`. tasks-axi is authoritative for edges and state; this is the membership roster and a readable snapshot.}

## Autonomy envelope
max-tasks: $max_tasks
max-spend-usd: $max_spend
max-wallclock-hours: $max_hours

## Completion rollup
Not yet tracked. Updated as the mission advances: tasks landed / total.
EOF
  echo "$id"
  echo "scaffolded: $f"
}

# Replace a heading's section body (everything up to the next "## " heading or EOF)
# with the given replacement text. Normalizes spacing to one blank line before the
# next heading, so repeated edits keep the file consistently formatted.
replace_section() {
  f=$1 heading=$2 body=$3
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-mission.XXXXXX") || die "mktemp failed"
  awk -v head="$heading" -v body="$body" '
    BEGIN { armed = 0 }
    {
      if ($0 == head) { print; print body; armed = 1; next }
      if (armed == 1) {
        if ($0 ~ /^## /) { print ""; print $0; armed = 0; next }
        next   # drop the old section body (blanks and content alike)
      }
      print
    }
  ' "$f" > "$tmp" || { rm -f "$tmp"; die "failed to rewrite $f"; }
  mv -f "$tmp" "$f"
}

cmd_set_criteria() {
  id=$1; shift
  src=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) src=${2:?--file needs a path}; shift 2 ;;
      --*)    die "unknown flag '$1' (see --help)" ;;
      *)      die "unexpected argument '$1'" ;;
    esac
  done
  f=$(file_for "$id")
  [ -f "$f" ] || die "no mission on file for '$id' (run: fm-mission.sh new ...)"
  grep -qxF '## Acceptance criteria' "$f" || die "mission '$id' has no '## Acceptance criteria' heading"
  if [ -n "$src" ]; then
    [ -f "$src" ] || die "criteria file not found: $src"
    body=$(cat "$src")
  else
    body=$(cat)
  fi
  [ -n "$body" ] || die "set-criteria needs non-empty criteria (from --file or stdin)"
  replace_section "$f" '## Acceptance criteria' "$body"
  echo "criteria set: $f"
  check_one "$id" || return 1
  return 0
}

cmd_add_task() {
  id=$1; shift || die "add-task needs a mission id and a task-id"
  task=${1:?add-task needs a task-id}; shift
  deps=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --blocked-by) deps+=("${2:?--blocked-by needs a task-id}"); shift 2 ;;
      --*)          die "unknown flag '$1' (see --help)" ;;
      *)            die "unexpected argument '$1'" ;;
    esac
  done
  f=$(file_for "$id")
  [ -f "$f" ] || die "no mission on file for '$id' (run: fm-mission.sh new ...)"
  grep -qxF '## Task DAG' "$f" || die "mission '$id' has no '## Task DAG' heading"
  line="- $task"
  if [ "${#deps[@]}" -gt 0 ]; then
    joined=$(printf '%s, ' "${deps[@]}"); joined=${joined%, }
    line="$line [blocked-by: $joined]"
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-mission.XXXXXX") || die "mktemp failed"
  # Rewrite the "## Task DAG" section: keep existing task lines contiguous, drop the
  # scaffold placeholder, blank lines, and any prior line for the same task-id, then
  # append this task at the section's end so re-adding a task-id is idempotent.
  # Normalizes to one blank line before the next heading.
  awk -v head='## Task DAG' -v task="$task" -v line="$line" '
    BEGIN { armed = 0; placed = 0 }
    {
      if ($0 == head) { print; armed = 1; next }
      if (armed == 1) {
        if ($0 ~ /^## /) {                                        # end of section
          if (!placed) { print line; placed = 1 }
          print ""; print $0; armed = 0; next
        }
        if ($0 ~ /^[[:space:]]*$/) next                           # drop blanks
        if ($0 ~ /^[[:space:]]*\{.*\}[[:space:]]*$/) next         # drop placeholder
        if ($0 == line) next                                      # dedupe exact
        if ($0 ~ ("^- " task "([ \t]|$|\\[)")) next               # drop prior same-id
        print; next
      }
      print
    }
    END { if (armed == 1 && !placed) print line }                 # section ran to EOF
  ' "$f" > "$tmp" || { rm -f "$tmp"; die "failed to rewrite $f"; }
  mv -f "$tmp" "$f"
  echo "recorded task in DAG: $line"
}

cmd_tasks() {
  id=$1
  f=$(file_for "$id")
  [ -f "$f" ] || die "no mission on file for '$id' (run: fm-mission.sh new ...)"
  # Print the first token of each "- <task-id> ..." line inside the Task DAG
  # section: the membership roster, nothing more. Skips the scaffold placeholder.
  awk '
    /^## Task DAG/ { indag = 1; next }
    indag && /^## / { indag = 0 }
    indag && /^- / {
      line = substr($0, 3)
      sub(/[ \t].*$/, "", line)
      if (line != "") print line
    }
  ' "$f"
}

cmd_set_rollup() {
  id=$1; shift
  src=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) src=${2:?--file needs a path}; shift 2 ;;
      --*)    die "unknown flag '$1' (see --help)" ;;
      *)      die "unexpected argument '$1'" ;;
    esac
  done
  f=$(file_for "$id")
  [ -f "$f" ] || die "no mission on file for '$id' (run: fm-mission.sh new ...)"
  grep -qxF '## Completion rollup' "$f" || die "mission '$id' has no '## Completion rollup' heading"
  if [ -n "$src" ]; then
    [ -f "$src" ] || die "rollup file not found: $src"
    body=$(cat "$src")
  else
    body=$(cat)
  fi
  [ -n "$body" ] || die "set-rollup needs non-empty text (from --file or stdin)"
  replace_section "$f" '## Completion rollup' "$body"
  echo "rollup set: $f"
}

# Validate one mission. Prints diagnostics; returns 1 on a hard failure.
check_one() {
  id=$1
  f=$(file_for "$id")
  rc=0
  if [ ! -f "$f" ]; then
    echo "MISSION_MISSING: $id (no data/missions/$id.md)"
    return 0
  fi

  for h in "${REQUIRED_HEADINGS[@]}"; do
    if ! grep -qxF "$h" "$f"; then
      echo "MISSION_INVALID: $id is missing the heading '$h'"
      rc=1
    fi
  done

  # Envelope: each key present exactly once with a positive-integer value.
  for k in "${ENVELOPE_KEYS[@]}"; do
    v=$(awk -v k="$k" '$1 == k":" { print $2; found=1 } END { if (!found) print "" }' "$f")
    if [ -z "$v" ]; then
      echo "MISSION_INVALID: $id envelope is missing '$k:'"
      rc=1
    else
      case "$v" in
        ''|*[!0-9]*) echo "MISSION_INVALID: $id envelope '$k' is not a positive integer ('$v')"; rc=1 ;;
        *) [ "$v" -gt 0 ] || { echo "MISSION_INVALID: $id envelope '$k' must be greater than zero"; rc=1; } ;;
      esac
    fi
  done

  if grep -q '{' "$f"; then
    echo "MISSION_STUB: $id still has unfilled {...} placeholders"
  fi

  return "$rc"
}

cmd_check() {
  rc=0
  if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    check_one "$1" || rc=1
    return "$rc"
  fi
  for id in $(list_missions); do
    check_one "$id" || rc=1
  done
  return "$rc"
}

list_missions() {
  [ -d "$MISSIONDIR" ] || return 0
  find "$MISSIONDIR" -mindepth 1 -maxdepth 1 -name '*.md' -exec basename {} .md \; 2>/dev/null | sort
}

cmd_list() {
  local any=0
  for id in $(list_missions); do
    any=1
    f=$(file_for "$id")
    tasks=$(awk '
      /^## Task DAG/ { indag = 1; next }
      indag && /^## / { indag = 0 }
      indag && /^- / { n++ }
      END { print n + 0 }
    ' "$f")
    printf '%s\t%s tasks\n' "$id" "$tasks"
  done
  [ "$any" -eq 1 ] || echo "no missions on file"
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac

ACTION=$1
shift || true

case "$ACTION" in
  new)          cmd_new "$@" ;;
  path)         [ "$#" -ge 1 ] || die "path needs a mission id"; cmd_path "$1" ;;
  show)         [ "$#" -ge 1 ] || die "show needs a mission id"; cmd_show "$1" ;;
  list)         cmd_list ;;
  check)        cmd_check "${1:-}" ;;
  set-criteria) [ "$#" -ge 1 ] || die "set-criteria needs a mission id"; cmd_set_criteria "$@" ;;
  add-task)     [ "$#" -ge 2 ] || die "add-task needs a mission id and a task-id"; cmd_add_task "$@" ;;
  tasks)        [ "$#" -ge 1 ] || die "tasks needs a mission id"; cmd_tasks "$1" ;;
  set-rollup)   [ "$#" -ge 1 ] || die "set-rollup needs a mission id"; cmd_set_rollup "$@" ;;
  *)            die "unknown action '$ACTION' (see --help)" ;;
esac
