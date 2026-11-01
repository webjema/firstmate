#!/usr/bin/env bash
# tests/asana-helpers.sh - a fake Asana for the suites that drive bin/fm-asana-lib.sh.
#
# NO TEST MAY REACH THE REAL ASANA API. install_fake_curl puts a `curl` on the fakebin that
# speaks the same wire shape the scripts read (body, newline, HTTP status, matching curl's
# -w '\n%{http_code}') over a JSON store, so a test drives the real request path.
#
# $FAKE_ASANA_STORE is a JSON array of cards {gid,name,notes,project,section,completed,tags}.
# Every board shares one store; a scan serves only the cards of the project or section in the
# URL. $FAKE_ASANA_SECTIONS is a JSON array of {gid,name,project}; $FAKE_ASANA_TAGS a JSON
# array of {gid,name}. $FAKE_ASANA_LOG records one "<METHOD> <url>" line per request;
# $FAKE_ASANA_ADDPROJECT, $FAKE_ASANA_ADDTAG and $FAKE_ASANA_STORIES record request bodies,
# the stories as one {gid,text} object per line.
# $FAKE_ASANA_FAIL makes every request fail like an outage; $FAKE_ASANA_ENDLESS makes the
# project scan always claim another page, so the page cap can be driven.

install_fake_curl() {  # <fakebin>
  cat > "$1/curl" <<'SH'
#!/usr/bin/env bash
set -u
url=""; method=GET; body=""; prev=""
for a in "$@"; do
  case "$prev" in
    -X) method=$a ;;
    --data-binary) body=$a ;;
  esac
  case "$a" in
    http*) url=$a ;;
  esac
  prev=$a
done
printf '%s %s\n' "$method" "$url" >> "$FAKE_ASANA_LOG"
if [ -n "${FAKE_ASANA_FAIL:-}" ]; then
  echo "curl: (7) Failed to connect" >&2
  exit 7
fi
store=$FAKE_ASANA_STORE
[ -s "$store" ] || printf '[]\n' > "$store"
path=${url#*/api/1.0}
route=${path%%\?*}
id_after() { local r=${route#*/"$1"/}; printf '%s' "${r%%/*}"; }
update() {  # [jq args...] <filter over the store>
  jq "$@" "$store" > "$store.tmp" && mv "$store.tmp" "$store"
}
case "$method $route" in
  "GET /projects/"*"/sections")
    jq --arg p "$(id_after projects)" '{data: [.[] | select(.project == $p) | {gid, name}]}' \
      "${FAKE_ASANA_SECTIONS:?}"
    printf '\n200\n' ;;
  "GET /projects/"*"/tasks")
    if [ -n "${FAKE_ASANA_ENDLESS:-}" ]; then
      jq -n '{data:[],next_page:{offset:"more"}}'
    else
      jq --arg p "$(id_after projects)" \
        '{data: [.[] | select((.project // $p) == $p)], next_page: null}' "$store"
    fi
    printf '\n200\n' ;;
  "GET /projects/"*)
    jq -n '{data:{workspace:{gid:"ws1"}}}'
    printf '\n200\n' ;;
  "GET /workspaces/"*"/tags")
    jq '{data: ., next_page: null}' "${FAKE_ASANA_TAGS:?}"
    printf '\n200\n' ;;
  "GET /sections/"*"/tasks")
    jq --arg s "$(id_after sections)" \
      '{data: [.[] | select(.section == $s and (.completed // false | not))
        | {gid, name, notes, created_at: (.created_at // "2026-10-01T00:00:00.000Z"),
           tags: [(.tags // [])[] | {name: .}]}], next_page: null}' "$store"
    printf '\n200\n' ;;
  "GET /tasks/"*"/stories")
    { [ -f "$FAKE_ASANA_STORIES" ] && cat "$FAKE_ASANA_STORIES"; true; } |
      jq -s --arg g "$(id_after tasks)" \
        '{data: [.[] | select(.gid == $g) | {text, resource_subtype: "comment_added"}], next_page: null}'
    printf '\n200\n' ;;
  "GET /tasks/"*)
    if jq -e --arg g "$(id_after tasks)" 'any(.[]; .gid == $g)' "$store" >/dev/null; then
      jq --arg g "$(id_after tasks)" '.[] | select(.gid == $g)
        | {data: {gid, name, notes, completed: (.completed // false),
                  memberships: [{project: {gid: .project}, section: {gid: (.section // "")}}]}}' "$store"
      printf '\n200\n'
    else
      printf '{"errors":[{"message":"Unknown object"}]}\n404\n'
    fi ;;
  "PUT /tasks/"*)
    update --arg g "$(id_after tasks)" --argjson b "$body" \
      'map(if .gid == $g then . + $b.data else . end)'
    printf '{"data":{}}\n200\n' ;;
  "POST /tasks/"*"/addProject")
    printf '%s\n' "$body" >> "$FAKE_ASANA_ADDPROJECT"
    update --arg g "$(id_after tasks)" --argjson b "$body" \
      'map(if .gid == $g then . + {project: $b.data.project, section: $b.data.section} else . end)'
    printf '{"data":{}}\n200\n' ;;
  "POST /tasks/"*"/addTag")
    printf '%s\n' "$body" >> "$FAKE_ASANA_ADDTAG"
    printf '{"data":{}}\n200\n' ;;
  "POST /tasks/"*"/stories")
    printf '%s' "$body" | jq -c --arg g "$(id_after tasks)" '{gid: $g, text: .data.text}' \
      >> "$FAKE_ASANA_STORIES"
    printf '{"data":{}}\n201\n' ;;
  "POST /tasks")
    gid=$(( $(jq 'length' "$store") + 700001 ))
    update --arg g "$gid" --argjson b "$body" \
      '. + [{gid: $g, name: $b.data.name, notes: $b.data.notes, project: $b.data.projects[0]}]'
    jq -n --arg g "$gid" '{data:{gid:$g, permalink_url:("https://app.asana.com/0/1/" + $g)}}'
    printf '\n201\n' ;;
  *)
    printf '{"errors":[{"message":"unexpected"}]}\n404\n' ;;
esac
exit 0
SH
  chmod +x "$1/curl"
}

# Points every FAKE_ASANA_* path into <dir> and empties the store and the logs. The sections
# and tags files start empty; a suite writes the boards it needs.
reset_fake_asana() {  # <dir>
  export FAKE_ASANA_STORE="$1/asana-store.json"
  export FAKE_ASANA_SECTIONS="$1/asana-sections.json"
  export FAKE_ASANA_TAGS="$1/asana-tags.json"
  export FAKE_ASANA_LOG="$1/asana.log"
  export FAKE_ASANA_ADDPROJECT="$1/addproject.log"
  export FAKE_ASANA_ADDTAG="$1/addtag.log"
  export FAKE_ASANA_STORIES="$1/stories.jsonl"
  unset FAKE_ASANA_FAIL FAKE_ASANA_ENDLESS
  printf '[]\n' > "$FAKE_ASANA_STORE"
  printf '[]\n' > "$FAKE_ASANA_SECTIONS"
  printf '[]\n' > "$FAKE_ASANA_TAGS"
}
