# shellcheck shell=bash
# shellcheck disable=SC2034  # the globals set here are read by the sourcing scripts
# The product-board (Asana) half shared by bin/fm-file-finding.sh, which files findings onto
# a board, bin/fm-triage-findings.sh, which drains its Triage section, and
# bin/fm-asana-close-fixed.sh, which closes a card when a PR that fixes it merges.
# bin/fm-file-finding.sh's header (ASANA TARGET) owns the config contract this reads.
# Usage: set CONFIG and WORK (a private temp dir), then `. bin/fm-asana-lib.sh`.
#
# Reads $CONFIG/product-tracker into DEFAULT_PROJECT, DEFAULT_SECTION, TRACKER_MAP and the
# three section NAMES (ROADMAP_SECTION_NAME, QUEUE_SECTION_NAME, CAPTAIN_SECTION_NAME). Names,
# not gids, because one name holds on every board while a gid names a section on one board.

ASANA_API="${FM_ASANA_API:-https://app.asana.com/api/1.0}"
ENV_PROJECT="${FM_ASANA_PROJECT:-}"
ENV_SECTION="${FM_ASANA_SECTION:-}"
DEFAULT_PROJECT="$ENV_PROJECT"
DEFAULT_SECTION="$ENV_SECTION"
ROADMAP_SECTION_NAME=""
QUEUE_SECTION_NAME=""
CAPTAIN_SECTION_NAME=""
# The repo-qualified lines, one `project.<repo>=<gid>` or `section.<repo>=<gid>` per line,
# in file order so a duplicate key is first-wins like the bare ones. Held as text rather
# than an associative array because that is bash 4 and this fleet still runs stock macOS
# bash, and because the repository the target is chosen for is not known until a finding is
# read: `flush` files a batch of held findings, each about its own repository.
TRACKER_MAP=""
# The env vars are read above, so "keep what is already set" is what makes them win over the
# file. A file with no trailing newline still yields its last line.
if [ -f "$CONFIG/product-tracker" ]; then
  while IFS='=' read -r k v || [ -n "$k" ]; do
    k=$(printf '%s' "$k" | tr -d '[:space:]')
    # A section name keeps its inner spaces ("Needs captain"); a gid has none to lose.
    name=$(printf '%s' "${v:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    v=$(printf '%s' "${v:-}" | tr -d '[:space:]')
    case "$k" in
      project) [ -n "$DEFAULT_PROJECT" ] || DEFAULT_PROJECT=$v ;;
      section) [ -n "$DEFAULT_SECTION" ] || DEFAULT_SECTION=$v ;;
      roadmap-section) [ -n "$ROADMAP_SECTION_NAME" ] || ROADMAP_SECTION_NAME=$name ;;
      queue-section) [ -n "$QUEUE_SECTION_NAME" ] || QUEUE_SECTION_NAME=$name ;;
      captain-section) [ -n "$CAPTAIN_SECTION_NAME" ] || CAPTAIN_SECTION_NAME=$name ;;
      project.?*|section.?*) TRACKER_MAP="$TRACKER_MAP$k=$v"$'\n' ;;
    esac
  done < "$CONFIG/product-tracker"
fi
ROADMAP_SECTION_NAME="${ROADMAP_SECTION_NAME:-Roadmap}"
QUEUE_SECTION_NAME="${QUEUE_SECTION_NAME:-Agent queue}"
CAPTAIN_SECTION_NAME="${CAPTAIN_SECTION_NAME:-Needs captain}"
# The live target, re-chosen per finding by asana_target_for below.
ASANA_PROJECT="$DEFAULT_PROJECT"
ASANA_SECTION="$DEFAULT_SECTION"
SCAN_PAGES="${FM_FINDING_SCAN_PAGES:-20}"
HTTP_TIMEOUT="${FM_FINDING_HTTP_TIMEOUT:-20}"

API_BODY=""
API_ERR=""

# The value of a repo-qualified config line, on stdout. Returns non-zero when the line is
# absent, which is a different thing from a line whose value is empty: one is "this repo has
# no board of its own" and the other is a broken mapping that must never default.
tracker_lookup() {  # <project|section> <repo>
  local want="$1.$2=" line
  while IFS= read -r line; do
    # The repo is interpolated into a case pattern, so it is quoted: a glob character in a
    # repository name must match itself, not whatever else the map happens to hold.
    case "$line" in
      "$want"*) printf '%s' "${line#"$want"}"; return 0 ;;
    esac
  done <<EOF
$TRACKER_MAP
EOF
  return 1
}

# Every board this home files onto, one gid per line. A card on no configured board is not
# this fleet's to change.
tracker_boards() {
  [ -z "$DEFAULT_PROJECT" ] || printf '%s\n' "$DEFAULT_PROJECT"
  [ -n "$ENV_PROJECT" ] && return 0
  printf '%s' "$TRACKER_MAP" | sed -n 's/^project\.[^=]*=\(..*\)$/\1/p'
}

# Chooses the board for the repository a finding is ABOUT, into ASANA_PROJECT/ASANA_SECTION.
# Returns non-zero with API_ERR set when the repo names a mapping that cannot be used, so
# the caller holds the finding; falling back to the default board there is the misroute this
# whole per-repo target exists to end.
asana_target_for() {  # <repo>
  local repo=$1 project section has_project=0 has_section=0
  ASANA_PROJECT="$DEFAULT_PROJECT"
  ASANA_SECTION="$DEFAULT_SECTION"
  [ -n "$repo" ] || return 0
  # FM_ASANA_PROJECT points the whole run at one board, so the map is not consulted at all -
  # not even to reject a line that run will never read.
  [ -z "$ENV_PROJECT" ] || return 0
  project=$(tracker_lookup project "$repo") && has_project=1
  section=$(tracker_lookup section "$repo") && has_section=1
  if [ "$has_project" -eq 1 ] && [ -z "$project" ]; then
    API_ERR="config/product-tracker: 'project.$repo=' names no board - fix the line and re-file with 'fm-file-finding.sh flush'"
    return 1
  fi
  if [ "$has_project" -eq 0 ] && [ "$has_section" -eq 1 ]; then
    API_ERR="config/product-tracker: 'section.$repo=$section' has no 'project.$repo=' beside it, and a section gid does not name a board - fix the line and re-file with 'fm-file-finding.sh flush'"
    return 1
  fi
  [ "$has_project" -eq 1 ] || return 0
  ASANA_PROJECT="$project"
  # Never the default section, and never FM_ASANA_SECTION either: both are gids on the board
  # this repo just moved off, and a section gid means nothing on any other board.
  ASANA_SECTION="$section"
  return 0
}

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

asana_ready() {
  [ -n "${ASANA_ACCESS_TOKEN:-}" ] || { API_ERR="ASANA_ACCESS_TOKEN is not set"; return 1; }
  command -v curl >/dev/null 2>&1 || { API_ERR="curl is not installed"; return 1; }
}

asana_url_for() { printf 'https://app.asana.com/0/%s/%s' "$1" "$2"; }

# Sets SECTION_GID to the gid of the section called <name> on <project>, or "" when the
# board has none. Returns non-zero only when the board could not be read.
SECTION_GID=""
asana_section_named() {  # <project> <name>
  SECTION_GID=""
  asana_api GET "/projects/$1/sections?opt_fields=name&limit=100" || return 1
  SECTION_GID=$(printf '%s' "$API_BODY" |
    jq -r --arg n "$2" '.data[]? | select((.name // "" | ascii_downcase) == ($n | ascii_downcase)) | .gid' |
    head -1) || SECTION_GID=""
}

# Writes the open cards of a section to <out>, one JSON object per line with gid, name,
# notes, created_at and tags. Paged like the trailer scan, and for the same reason a page
# cap is a failure: a list that may be missing cards must not read as complete. <max> stops
# early once that many cards are in hand, for a caller that wants a bounded batch.
asana_open_cards() {  # <section> <out> [max]
  local section=$1 out=$2 max=${3:-0} offset="" page=0 query
  : > "$out"
  while [ "$page" -lt "$SCAN_PAGES" ]; do
    query="/sections/$section/tasks?opt_fields=name,notes,created_at,tags.name&limit=100&completed_since=now"
    [ -n "$offset" ] && query="$query&offset=$offset"
    asana_api GET "$query" || return 1
    printf '%s' "$API_BODY" | jq -e '.data | type == "array"' >/dev/null 2>&1 || {
      API_ERR="section list returned an unreadable payload: $(printf '%s' "$API_BODY" | tr '\n' ' ' | cut -c1-120)"
      return 1
    }
    printf '%s' "$API_BODY" | jq -c '.data[]' >> "$out"
    if [ "$max" -gt 0 ] && [ "$(wc -l < "$out")" -ge "$max" ]; then return 0; fi
    offset=$(printf '%s' "$API_BODY" | jq -r '.next_page.offset // empty' 2>/dev/null || printf '')
    [ -n "$offset" ] || return 0
    page=$((page + 1))
  done
  API_ERR="section list cap of $SCAN_PAGES pages reached"
  return 1
}

asana_comment() {  # <task-gid> <text>
  asana_api POST "/tasks/$1/stories" "$(jq -n --arg t "$2" '{data:{text:$t}}')"
}

asana_complete() {  # <task-gid>
  asana_api PUT "/tasks/$1" '{"data":{"completed":true}}'
}

asana_move() {  # <task-gid> <project> <section>
  asana_api POST "/tasks/$1/addProject" \
    "$(jq -n --arg p "$2" --arg s "$3" '{data:{project:$p,section:$s}}')"
}
