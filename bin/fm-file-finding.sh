#!/usr/bin/env bash
# File a finding you did not fix as a tracked task, so it becomes work instead of a
# line in a report nobody re-reads. AGENTS.md section 5 owns the RULE (when to file,
# when to escalate instead); this header owns the MECHANICS.
#
# Usage:
#   fm-file-finding.sh --title <t> --where <file:line> --why <w> --expected <e>
#                      --blocking <yes|no>
#                      [--scope product|fleet] [--repo <name>] [--task <id>]
#                      [--key <slug>] [--priority <0-4>]
#   fm-file-finding.sh flush        re-file every finding held locally by an earlier outage
#
# --blocking IS the rule's one question, made mechanical: "does this stop me finishing
# the task I am on?". It is required, and `--blocking yes` is REFUSED - filing is not a
# way to skip a blocker. The refusal prints the escalation path (fix it if the scope is
# small and adjacent, otherwise append `blocked:`/`needs-decision:` and stop) and exits 2
# without writing a record or calling any tracker.
#
# ROUTING - the one-line rule is "does a human tracking the user's product need to see
# this?", and the default answer is computed rather than asked:
#   fleet    the finding is about firstmate's own tooling. Detected when the finding's
#            repository shares a git common dir with the repo this script lives in - true
#            for the primary checkout, for a pooled worktree of it, and for a secondmate
#            home (itself a firstmate worktree). Files to $FM_HOME/data/backlog.md.
#   product  everything else, and the fallback when the git probe fails. Files to the
#            Asana project/section below. A stale key in bin/fm-pool-lib.sh does not
#            belong on the user's product board, which is the whole point of the split.
# The probe runs against the repository the finding is ABOUT, which is not always the
# caller's cwd: firstmate reviews a crew's diff from its own checkout, so probing $PWD
# alone would file every product finding it raises into the fleet backlog. Resolution
# order: `--task <id>`'s recorded worktree, then `--repo <name>` under $FM_HOME/projects/,
# then $PWD. --scope overrides the probe outright, and --repo also names the repository in
# the filed task; left unset it defaults to the basename of the directory holding the git
# common dir, which is the repository name for a worktree as well as a checkout.
#
# BACKLOG TARGET. `tasks-axi add --queue` followed by `tasks-axi hold --kind captain`, so a
# fleet finding lands non-dispatchable and firstmate's "re-evaluate Queued" sweep cannot
# turn it into work before a human has read it - the backlog's equivalent of the Asana
# Triage section. bin/fm-tasks-axi-lib.sh owns whether that backend may be used; when it
# says no (tool absent, too old, or config/backlog-backend=manual) the row and its hold are
# appended to backlog.md directly, which AGENTS.md section 9 sanctions and which is better
# than holding a finding hostage to a tool version.
#
# ASANA TARGET. A local knob, never a built-in default: which tracker a fleet files into is
# a decision only its user can make, and a shipped default would point every other install
# at a board it does not own. $FM_HOME/config/product-tracker (local, gitignored) carries
# `project=<gid>` and `section=<gid>`, one per line; FM_ASANA_PROJECT / FM_ASANA_SECTION
# override per key. With no project configured, a product finding takes the OUTAGE path
# below - held locally with the reason "no product tracker configured", which reads
# differently from an unreachable tracker on purpose, because only one of the two is fixed
# by waiting. With a project but no section the card is still filed, into wherever the board
# puts a sectionless task, and the script warns. A section is wanted because it should be a
# triage one rather than the pipeline's own queue: a filed finding must be read by a human
# before it becomes authorized work, so filing never auto-starts work. Auth is
# ASANA_ACCESS_TOKEN, which bin/fm-spawn.sh forwards to every crew through a 0600 file,
# so a crewmate can file the moment it finds something - the finding survives a firstmate
# restart or a context compaction, which a finding that only exists in a status line does
# not. FM_ASANA_API overrides the API base for testing; no test may reach the real API.
# The card is created with POST /tasks (into the project) and then moved to the section
# with POST /tasks/<gid>/addProject. If the move fails the card still exists and is still
# deduplicated, so the script warns rather than retrying or unwinding. The token goes to
# curl through a 0600 --config file, never on the command line, because /proc/<pid>/cmdline
# is world-readable - the same reason bin/fm-spawn.sh refuses to pass it as a tmux -e value.
# --priority sets the backlog task's priority field; Asana has no equivalent standard field,
# so on that route the severity is recorded in the notes as prose and nothing more.
#
# IDEMPOTENCE. Every finding carries a hidden trailer `[fm-finding: <12 hex>]` as the last
# line of the card notes (Asana) or the task body (backlog). The key is the sha256 of the
# lowercased, whitespace-collapsed title + where + repo, so the same defect found twice -
# by a retried stage, a resumed crew, or a second crew - resolves to the same key even
# when the wording of `--why` differs. `--key` sets it explicitly.
# Three layers, cheapest first:
#   1. the local record under $FM_HOME/state/findings/<key>.json, if it says `filed`;
#   2. a scan of the tracker for the trailer - the authoritative check, and the one that
#      still works after the local record is gone. Asana: GET /projects/<gid>/tasks with
#      completed_since=now (open tasks only) paginated to FM_FINDING_SCAN_PAGES pages
#      (default 20 x 100). Exhausting the cap without a match means "cannot verify", which
#      defers rather than risking a duplicate. Backlog: grep the trailer in backlog.md.
#   3. only then create.
# This is idempotence across time, not across concurrent callers: two crews filing the same
# finding in the same second both scan, both miss, and both create. Not worth a lock - the
# case that matters is the same crew retrying, and a rare duplicate card is cheap.
#
# OUTAGE. A tracker that is unreachable must never fail a task and must never lose the
# finding, so it does neither: the record under $FM_HOME/state/findings/ is written BEFORE
# any network call and left in state `pending`, the script prints `deferred:` and exits 0,
# and `fm-file-finding.sh flush` re-files every pending record later. The record is in the
# home's state dir, not the worktree, so it outlives teardown. Nobody has to remember that
# flush: any later run that files successfully drains the held records too, and
# bin/fm-session-start.sh counts what is still held in its fleet-state digest.
#
# Exit status: 0 when the finding is filed, already filed, or safely deferred; 2 for a
# usage error or a refused blocker.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fm_pool_sha256 (the repo's one sha256 ladder: stock macOS has shasum, not sha256sum) and
# fm_tasks_axi_backend_available (the one owner of "may this home use tasks-axi").
# shellcheck source=bin/fm-pool-lib.sh
. "$SCRIPT_DIR/fm-pool-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FINDINGS="$STATE/findings"

ASANA_API="${FM_ASANA_API:-https://app.asana.com/api/1.0}"
ASANA_PROJECT="${FM_ASANA_PROJECT:-}"
ASANA_SECTION="${FM_ASANA_SECTION:-}"
# The env vars are set above, so "keep what is already set" is what makes them win over the
# file. A file with no trailing newline still yields its last line.
if [ -f "$CONFIG/product-tracker" ]; then
  while IFS='=' read -r k v || [ -n "$k" ]; do
    k=$(printf '%s' "$k" | tr -d '[:space:]')
    v=$(printf '%s' "${v:-}" | tr -d '[:space:]')
    case "$k" in
      project) [ -n "$ASANA_PROJECT" ] || ASANA_PROJECT=$v ;;
      section) [ -n "$ASANA_SECTION" ] || ASANA_SECTION=$v ;;
    esac
  done < "$CONFIG/product-tracker"
fi
SCAN_PAGES="${FM_FINDING_SCAN_PAGES:-20}"
HTTP_TIMEOUT="${FM_FINDING_HTTP_TIMEOUT:-20}"

die() { echo "fm-file-finding.sh: $1" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-finding.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- repository probe --------------------------------------------------------
# One `git rev-parse` answers both "which repo is this finding about" and "is that
# firstmate's own repo". Prints "<common-dir>|<repo-name>", or nothing when the probe
# fails (not a repo, no git); every caller treats an empty answer as unknown.
repo_probe() {
  local dir=$1 common
  command -v git >/dev/null 2>&1 || return 0
  common=$(cd "$dir" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) || return 0
  [ -n "$common" ] || return 0
  case "$common" in
    /*) ;;
    *) common=$(cd "$dir" && cd "$common" 2>/dev/null && pwd -P) || return 0 ;;
  esac
  printf '%s|%s\n' "$common" "$(basename "$(dirname "$common")")"
}

# The directory whose repository the finding is ABOUT. A crewmate files from inside the
# worktree it is working in, so $PWD is right for it - but firstmate reviews that crew's
# diff from its own checkout, and probing $PWD there would route every product finding it
# raises into the fleet backlog. Naming the task or the repo says which repo is meant.
subject_dir() {
  local wt
  if [ -n "$TASK" ] && [ -f "$STATE/$TASK.meta" ]; then
    wt=$(sed -n 's/^worktree=//p' "$STATE/$TASK.meta" | head -1)
    if [ -n "$wt" ] && [ -d "$wt" ]; then printf '%s' "$wt"; return 0; fi
  fi
  if [ -n "$REPO" ] && [ -d "$FM_HOME/projects/$REPO" ]; then
    printf '%s' "$FM_HOME/projects/$REPO"
    return 0
  fi
  printf '%s' "$PWD"
}

# --- key -------------------------------------------------------------------
finding_key() {  # <title> <where> <repo>
  local hash
  hash=$(printf '%s\n%s\n%s\n' "$1" "$2" "$3" |
    tr '[:upper:]' '[:lower:]' |
    tr -s '[:space:]' ' ' |
    fm_pool_sha256)
  [ -n "$hash" ] || die "no sha256 tool found (sha256sum or shasum); pass --key to file anyway"
  printf '%s' "$hash" | cut -c1-12
}

trailer_for() { printf '[fm-finding: %s]' "$1"; }

# --- record ------------------------------------------------------------------
record_path() { printf '%s/%s.json' "$FINDINGS" "$1"; }

record_field() {  # <key> <field>
  jq -r --arg f "$2" '.[$f] // ""' "$(record_path "$1")" 2>/dev/null || printf ''
}

write_record() {  # <key> <json-object>
  mkdir -p "$FINDINGS"
  printf '%s\n' "$2" > "$(record_path "$1").tmp"
  mv "$(record_path "$1").tmp" "$(record_path "$1")"
}

update_record() {  # <key> <jq-filter> [--arg pairs...]
  local key=$1 filter=$2 path updated
  shift 2
  path=$(record_path "$key")
  updated=$(jq "$@" "$filter" "$path") || return 1
  printf '%s\n' "$updated" > "$path.tmp"
  mv "$path.tmp" "$path"
}

# --- Asana -------------------------------------------------------------------
API_BODY=""
API_ERR=""

# The token is written once to a 0600 file curl reads with --config, never passed as an
# argument: /proc/<pid>/cmdline is world-readable to every process on the box.
asana_auth_file() {
  local f="$WORK/curl.cfg"
  if [ ! -f "$f" ]; then
    (umask 077; printf 'header = "Authorization: Bearer %s"\n' "$ASANA_ACCESS_TOKEN" > "$f")
  fi
  printf '%s' "$f"
}

asana_api() {  # <method> <path> [json-body]
  local method=$1 path=$2 body=${3:-} out code rc=0
  local -a args=(-sS -m "$HTTP_TIMEOUT" -X "$method"
    --config "$(asana_auth_file)"
    -w '\n%{http_code}')
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data-binary "$body")
  fi
  API_BODY=""; API_ERR=""
  out=$(curl "${args[@]}" "$ASANA_API$path" 2>"$WORK/curl.err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    API_ERR="curl exit $rc: $(tr '\n' ' ' < "$WORK/curl.err" | cut -c1-200)"
    return 1
  fi
  code=${out##*$'\n'}
  API_BODY=${out%$'\n'*}
  case "$code" in
    2*) return 0 ;;
  esac
  API_ERR="HTTP $code: $(printf '%s' "$API_BODY" | tr '\n' ' ' | cut -c1-200)"
  return 1
}

# Sets FOUND_GID to the gid of an open card already carrying this trailer, or "".
# Returns non-zero when the tracker could not answer - never conflate "no match" with
# "could not look", because only the first is safe to create on. Not a $(...) helper:
# a command substitution runs in a subshell, and API_ERR set there never comes back.
FOUND_GID=""
asana_find() {  # <trailer>
  local trailer=$1 offset="" page=0 query
  FOUND_GID=""
  while [ "$page" -lt "$SCAN_PAGES" ]; do
    query="/projects/$ASANA_PROJECT/tasks?opt_fields=notes&limit=100&completed_since=now"
    [ -n "$offset" ] && query="$query&offset=$offset"
    asana_api GET "$query" || return 1
    # A 2xx whose body is not the task list - a proxy interstitial, a truncated read - must
    # not read as "looked, nothing there", or the create below duplicates the card. Prove
    # the payload is the shape being scanned before drawing any conclusion from it.
    printf '%s' "$API_BODY" | jq -e '.data | type == "array"' >/dev/null 2>&1 || {
      API_ERR="scan returned an unreadable payload: $(printf '%s' "$API_BODY" | tr '\n' ' ' | cut -c1-120)"
      return 1
    }
    FOUND_GID=$(printf '%s' "$API_BODY" |
      jq -r --arg t "$trailer" '.data[]? | select((.notes // "") | contains($t)) | .gid' |
      head -1) || FOUND_GID=""
    [ -z "$FOUND_GID" ] || return 0
    offset=$(printf '%s' "$API_BODY" | jq -r '.next_page.offset // empty' 2>/dev/null || printf '')
    [ -n "$offset" ] || return 0
    page=$((page + 1))
  done
  API_ERR="scan cap of $SCAN_PAGES pages reached without a verdict"
  return 1
}

asana_url_for() { printf 'https://app.asana.com/0/%s/%s' "$ASANA_PROJECT" "$1"; }

# Fills FILED_URL, and ALREADY=1 when the card was already there; sets API_ERR and
# returns non-zero otherwise.
FILED_URL=""
ALREADY=0
asana_file() {  # <title> <notes> <trailer>
  local title=$1 notes=$2 trailer=$3 gid payload
  # No configured board is a different thing from an unreachable one, and only one of them
  # is fixed by waiting, so it says so. Never a built-in default: which tracker a fleet
  # files into is the user's decision, and a stranger's board would swallow the finding.
  [ -n "$ASANA_PROJECT" ] || {
    API_ERR="no product tracker configured - set project= in $CONFIG/product-tracker (see --help)"
    return 1
  }
  [ -n "${ASANA_ACCESS_TOKEN:-}" ] || { API_ERR="ASANA_ACCESS_TOKEN is not set"; return 1; }
  command -v curl >/dev/null 2>&1 || { API_ERR="curl is not installed"; return 1; }

  asana_find "$trailer" || return 1
  if [ -n "$FOUND_GID" ]; then
    FILED_URL=$(asana_url_for "$FOUND_GID")
    ALREADY=1
    return 0
  fi

  payload=$(jq -n --arg n "$title" --arg b "$notes" --arg p "$ASANA_PROJECT" \
    '{data:{name:$n,notes:$b,projects:[$p]}}')
  asana_api POST "/tasks?opt_fields=permalink_url" "$payload" || return 1
  gid=$(printf '%s' "$API_BODY" | jq -r '.data.gid // empty' 2>/dev/null || printf '')
  [ -n "$gid" ] || { API_ERR="create returned no task gid"; return 1; }
  FILED_URL=$(printf '%s' "$API_BODY" | jq -r '.data.permalink_url // empty' 2>/dev/null || printf '')
  [ -n "$FILED_URL" ] || FILED_URL=$(asana_url_for "$gid")

  # A configured project with no section still files - the card exists and is deduplicated,
  # it just lands wherever the board puts a sectionless task. Worth a warning, not a refusal.
  if [ -z "$ASANA_SECTION" ]; then
    echo "warn: no triage section configured; $FILED_URL landed in the project's default place" >&2
    return 0
  fi
  payload=$(jq -n --arg p "$ASANA_PROJECT" --arg s "$ASANA_SECTION" \
    '{data:{project:$p,section:$s}}')
  asana_api POST "/tasks/$gid/addProject" "$payload" ||
    echo "warn: card $FILED_URL created but not moved into Triage ($API_ERR); move it by hand" >&2
  return 0
}

# --- backlog -----------------------------------------------------------------
backlog_file() { printf '%s/backlog.md' "$DATA"; }

backlog_file_finding() {  # <title> <body> <trailer> <repo> <priority>
  local title=$1 body=$2 trailer=$3 repo=$4 priority=$5 file out id rc=0
  file=$(backlog_file)
  # The trailer is written into the task body, and tasks-axi round-trips the body into
  # backlog.md byte for byte, so grepping the file is the same authoritative check the
  # Asana scan makes - and it works before tasks-axi is even installed.
  if [ -f "$file" ] && grep -F -- "$trailer" "$file" >/dev/null 2>&1; then
    FILED_URL="backlog $file"
    ALREADY=1
    return 0
  fi
  mkdir -p "$DATA"
  if ! fm_tasks_axi_backend_available "$CONFIG"; then
    backlog_append "$file" "$title" "$body" "$repo"
    FILED_URL="backlog $file"
    return 0
  fi
  printf '%s\n' "$body" > "$WORK/body.md"
  local -a args=(add "$title" --mint --queue --kind ship --body-file "$WORK/body.md"
    --file "$file" --json)
  [ -n "$repo" ] && args+=(--repo "$repo")
  [ -n "$priority" ] && args+=(--priority "$priority")
  out=$(tasks-axi "${args[@]}" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    API_ERR="tasks-axi add failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
    return 1
  fi
  id=$(printf '%s' "$out" | jq -r '.task.id // empty' 2>/dev/null || printf '')
  # Held, not merely queued: firstmate dispatches unblocked Queued work on every teardown
  # and heartbeat, so without this a filed finding would start work by itself - the one
  # thing the Triage section exists to prevent on the other route.
  if [ -n "$id" ]; then
    tasks-axi hold "$id" --reason "$HOLD_REASON" --kind captain --file "$file" >/dev/null 2>&1 ||
      echo "warn: filed $id but could not hold it; triage it before it is dispatched" >&2
  fi
  FILED_URL="backlog ${id:-$file}"
  return 0
}

HOLD_REASON="unreviewed finding - triage before dispatching"

# The hand-written equivalent, for a home whose tasks-axi is absent, too old, or opted out
# with config/backlog-backend=manual. AGENTS.md section 9 sanctions hand-editing exactly
# then, and it beats holding a finding hostage to a tool version. The row shape - including
# the `(hold: ...)` and `(hold-kind: ...)` suffixes - is what tasks-axi 0.2.x renders, so
# the file it writes is the file tasks-axi would have written.
backlog_append() {  # <file> <title> <body> <repo>
  local file=$1 title=$2 body=$3 repo=$4 id row
  id=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' |
    sed 's/^-//; s/-$//' | cut -c1-40)
  id="${id:-finding}-$(printf '%s' "$KEY" | cut -c1-2)"
  row="- [ ] $id - $title"
  [ -z "$repo" ] || row="$row (repo: $repo)"
  row="$row (kind: ship) (since $(date -u +%Y-%m-%d))"
  row="$row (hold: $HOLD_REASON) (hold-kind: captain)"
  if [ ! -f "$file" ]; then
    printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$file"
  fi
  if grep -q '^## Queued' "$file"; then
    awk -v row="$row" -v body="$body" '
      { print }
      /^## Queued$/ && !done { print row; n = split(body, lines, "\n");
        for (i = 1; i <= n; i++) print "  " lines[i]; done = 1 }
    ' "$file" > "$file.tmp"
  else
    { cat "$file"; printf '\n## Queued\n%s\n' "$row"; printf '%s\n' "$body" | sed 's/^/  /'; } > "$file.tmp"
  fi
  mv "$file.tmp" "$file"
}

# --- compose -----------------------------------------------------------------
# The four things the user named, in one body: what is wrong, where, WHY you believe it
# is wrong, and what you expected instead. The trailer is always the last line.
finding_body() {  # <key>
  local key=$1 why where expected repo task priority
  why=$(record_field "$key" why)
  where=$(record_field "$key" where)
  expected=$(record_field "$key" expected)
  repo=$(record_field "$key" repo)
  task=$(record_field "$key" task)
  priority=$(record_field "$key" priority)
  printf '%s\n\n' "$why"
  printf 'Where: %s\n' "$where"
  printf 'Expected instead: %s\n' "$expected"
  [ -z "$repo" ] || printf 'Repository: %s\n' "$repo"
  [ -z "$task" ] || printf 'Found while working on: %s\n' "$task"
  [ -z "$priority" ] || printf 'Severity: %s\n' "$priority"
  printf '\n%s\n' "$(trailer_for "$key")"
}

# Files the finding already recorded under <key>. Prints exactly one verdict line and
# never returns non-zero for a tracker problem: a tracker outage is not a task failure.
file_recorded() {  # <key>
  local key=$1 scope title body trailer ok=0
  scope=$(record_field "$key" scope)
  title=$(record_field "$key" title)
  trailer=$(trailer_for "$key")
  body=$(finding_body "$key")
  FILED_URL=""
  API_ERR=""
  ALREADY=0
  if [ "$scope" = fleet ]; then
    backlog_file_finding "$title" "$body" "$trailer" \
      "$(record_field "$key" repo)" "$(record_field "$key" priority)" || ok=1
  else
    asana_file "$title" "$body" "$trailer" || ok=1
  fi
  if [ "$ok" -eq 0 ]; then
    # shellcheck disable=SC2016  # $u is a jq variable bound by --arg, not a shell one.
    update_record "$key" '.state = "filed" | .url = $u | .error = ""' --arg u "$FILED_URL"
    if [ "$ALREADY" -eq 1 ]; then
      echo "already-filed: $FILED_URL [$key]"
    else
      echo "filed: $FILED_URL [$key]"
    fi
    return 0
  fi
  # shellcheck disable=SC2016  # $e is a jq variable bound by --arg, not a shell one.
  update_record "$key" '.state = "pending" | .error = $e' --arg e "$API_ERR"
  echo "deferred: $API_ERR - held at $(record_path "$key"); re-file with 'fm-file-finding.sh flush'"
  return 0
}

# --- flush -------------------------------------------------------------------
# Sets FLUSHED rather than printing it: the per-finding verdict lines from file_recorded
# are the output, and a captured count would swallow them.
FLUSHED=0
flush_pending() {  # [<key-to-skip>]
  local skip=${1:-} rec k
  FLUSHED=0
  for rec in "$FINDINGS"/*.json; do
    [ -e "$rec" ] || continue
    k=$(basename "$rec" .json)
    [ "$k" != "$skip" ] || continue
    [ "$(record_field "$k" state)" = pending ] || continue
    FLUSHED=$((FLUSHED + 1))
    file_recorded "$k"
  done
}

if [ "${1:-}" = flush ]; then
  [ $# -eq 1 ] || die "flush takes no other arguments"
  flush_pending
  [ "$FLUSHED" -gt 0 ] || echo "flush: no findings are waiting"
  exit 0
fi

# --- file --------------------------------------------------------------------
TITLE=""; WHERE=""; WHY=""; EXPECTED=""; BLOCKING=""
SCOPE=""; REPO=""; TASK=""; KEY=""; PRIORITY=""
while [ $# -gt 0 ]; do
  # Every flag below takes a value, so a trailing one would make `shift 2` return non-zero
  # and kill the script under `set -e` with no message at all instead of a usage error.
  case "$1" in
    --*) [ $# -ge 2 ] || die "$1 needs a value (see --help)" ;;
  esac
  case "$1" in
    --title) TITLE=${2:-}; shift 2 ;;
    --where) WHERE=${2:-}; shift 2 ;;
    --why) WHY=${2:-}; shift 2 ;;
    --expected) EXPECTED=${2:-}; shift 2 ;;
    --blocking) BLOCKING=${2:-}; shift 2 ;;
    --scope) SCOPE=${2:-}; shift 2 ;;
    --repo) REPO=${2:-}; shift 2 ;;
    --task) TASK=${2:-}; shift 2 ;;
    --key) KEY=${2:-}; shift 2 ;;
    --priority) PRIORITY=${2:-}; shift 2 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

for pair in "title:$TITLE" "where:$WHERE" "why:$WHY" "expected:$EXPECTED" "blocking:$BLOCKING"; do
  [ -n "${pair#*:}" ] || die "--${pair%%:*} is required (see --help)"
done

case "$BLOCKING" in
  no) ;;
  yes)
    cat >&2 <<'EOF'
fm-file-finding.sh: refused - this finding stops you finishing your task, so filing it is
not the answer. A blocker is raised, not queued: fix it in place only if the scope is small
and clearly adjacent and say that you did, otherwise append `blocked:` or `needs-decision:`
to your status file and stop. File it here only once it is no longer what stops you.
EOF
    exit 2
    ;;
  *) die "--blocking must be exactly 'yes' or 'no', got '$BLOCKING'" ;;
esac

command -v jq >/dev/null 2>&1 || die "jq is required"

PROBE=$(repo_probe "$(subject_dir)")
[ -n "$REPO" ] || REPO=${PROBE#*|}
if [ -z "$SCOPE" ]; then
  SCOPE=product
  if [ -n "$PROBE" ] && [ "${PROBE%%|*}" = "$(repo_probe "$FM_ROOT" | cut -d'|' -f1)" ]; then
    SCOPE=fleet
  fi
fi
case "$SCOPE" in
  product|fleet) ;;
  *) die "--scope must be 'product' or 'fleet', got '$SCOPE'" ;;
esac
case "$PRIORITY" in
  ''|[0-4]) ;;
  *) die "--priority must be 0-4, got '$PRIORITY'" ;;
esac

[ -n "$KEY" ] || KEY=$(finding_key "$TITLE" "$WHERE" "$REPO")

if [ "$(record_field "$KEY" state)" = filed ]; then
  echo "already-filed: $(record_field "$KEY" url) [$KEY]"
  exit 0
fi

write_record "$KEY" "$(jq -n \
  --arg key "$KEY" --arg scope "$SCOPE" --arg title "$TITLE" --arg where "$WHERE" \
  --arg why "$WHY" --arg expected "$EXPECTED" --arg repo "$REPO" --arg task "$TASK" \
  --arg priority "$PRIORITY" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{key:$key,scope:$scope,title:$title,where:$where,why:$why,expected:$expected,
    repo:$repo,task:$task,priority:$priority,created:$created,state:"pending",url:"",error:""}')"

file_recorded "$KEY"

# A finding held by an earlier outage recovers on its own the next time anything files
# successfully, so nobody has to remember `flush`. Only after a success: while the tracker
# is still down there is nothing to gain by asking it again for every held record.
if [ "$(record_field "$KEY" state)" = filed ]; then
  flush_pending "$KEY"
fi
