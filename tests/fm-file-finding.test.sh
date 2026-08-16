#!/usr/bin/env bash
# Behavior tests for bin/fm-file-finding.sh.
#
# NO TEST MAY REACH THE REAL ASANA API. Every one of them stubs `curl` at the HTTP
# boundary with a fake Asana that keeps its tasks in a JSON file, so the dedupe
# assertions drive the REAL scan-then-create path rather than a local flag: the create
# writes into the fake's store, and the second attempt finds it there. The one test that
# must never call out at all (a firstmate-internal finding) asserts on the ABSENCE of the
# curl log, so a routing regression that leaks a tooling finding onto the user's product
# board fails here rather than on the board.
#
# `tasks-axi` is stubbed too, so the backlog route does not depend on a tool CI does not
# have. The stub reproduces the one property the dedupe relies on, verified against
# tasks-axi 0.2.x by hand: `add --body-file` round-trips the body verbatim into
# backlog.md, so grepping the hidden trailer in that file is an authoritative check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-file-finding)
PROJECT_GID=9990001
SECTION_GID=9990002

# --- fixtures ---------------------------------------------------------------

# A fake Asana over the same wire shape bin/fm-file-finding.sh speaks: body, newline,
# HTTP status (matching curl's -w '\n%{http_code}'). $FAKE_ASANA_STORE holds a JSON array
# of {gid,notes}; the scan reads it and the create appends to it, so two runs against one
# store exercise the real deduplication. $FAKE_ASANA_LOG records one line per request.
# $FAKE_ASANA_FAIL makes every request fail like an outage; $FAKE_ASANA_ENDLESS makes the
# scan always claim another page, so the page cap can be driven.
install_fake_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
url=""; method=GET; body=""
prev=""
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
[ -s "$FAKE_ASANA_STORE" ] || printf '[]\n' > "$FAKE_ASANA_STORE"
case "$method $url" in
  "GET "*"/projects/"*"/tasks"*)
    if [ -n "${FAKE_ASANA_ENDLESS:-}" ]; then
      jq -n '{data:[],next_page:{offset:"more"}}'
    else
      jq '{data:., next_page:null}' "$FAKE_ASANA_STORE"
    fi
    printf '\n200\n'
    ;;
  "POST "*"/tasks/"*"/addProject")
    printf '%s' "$body" >> "$FAKE_ASANA_ADDPROJECT"
    printf '\n'  >> "$FAKE_ASANA_ADDPROJECT"
    printf '{"data":{}}\n200\n'
    ;;
  "POST "*"/tasks"*)
    gid=$(( $(jq 'length' "$FAKE_ASANA_STORE") + 700001 ))
    printf '%s' "$body" | jq --arg g "$gid" '{gid:$g, notes:.data.notes}' > "$FAKE_ASANA_STORE.new"
    jq -s '.[0] + [.[1]]' "$FAKE_ASANA_STORE" "$FAKE_ASANA_STORE.new" > "$FAKE_ASANA_STORE.tmp"
    mv "$FAKE_ASANA_STORE.tmp" "$FAKE_ASANA_STORE"
    jq -n --arg g "$gid" '{data:{gid:$g, permalink_url:("https://app.asana.com/0/1/" + $g)}}'
    printf '\n201\n'
    ;;
  *)
    printf '{"errors":[{"message":"unexpected"}]}\n404\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
}

# Reproduces the one tasks-axi property the backlog dedupe depends on: the body lands in
# backlog.md verbatim. Records its argv so the test can assert how often `add` ran.
install_fake_tasks_axi() {
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
# The compatibility probes bin/fm-tasks-axi-lib.sh runs before it will use this backend.
case "${1:-}" in
  --version) echo "tasks-axi 0.2.5"; exit 0 ;;
  update) echo "--archive-body"; exit 0 ;;
  mv) echo "usage: tasks-axi mv <id> [<id>...] <section>"; exit 0 ;;
esac
printf '%s\n' "$*" >> "$FAKE_TASKS_LOG"
file=""; bodyfile=""; reason=""; prev=""
for a in "$@"; do
  case "$prev" in
    --file) file=$a ;;
    --body-file) bodyfile=$a ;;
    --reason) reason=$a ;;
  esac
  prev=$a
done
case "${1:-}" in
  add)
    mkdir -p "$(dirname "$file")"
    [ -f "$file" ] || printf '# Backlog\n\n## Queued\n\n' > "$file"
    {
      printf -- '- [ ] finding-xx - %s\n' "$2"
      sed 's/^/  /' "$bodyfile"
    } >> "$file"
    printf '{"ok":true,"task":{"id":"finding-xx"}}\n'
    ;;
  hold)
    # tasks-axi renders a hold as suffixes on the task's own row.
    sed -i "s|^- \[ \] $2 - .*|& (hold: $reason) (hold-kind: captain)|" "$file"
    printf 'ok: hold %s -> held (captain)\n' "$2"
    ;;
esac
SH
  chmod +x "$fakebin/tasks-axi"
}

# A scratch home plus a non-firstmate project repo to run findings "from". Exports
# everything the fakes and the script read, so each test body is just the run + asserts.
new_case() {
  local name=$1 fakebin
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR/home/state" "$CASE_DIR/home/data"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/acme"
  fm_git_init_commit "$PROJ_DIR"
  fakebin=$(fm_fakebin "$CASE_DIR")
  install_fake_curl "$fakebin"
  install_fake_tasks_axi "$fakebin"
  export PATH="$fakebin:$PATH"
  export FAKE_ASANA_STORE="$CASE_DIR/asana-store.json"
  export FAKE_ASANA_LOG="$CASE_DIR/asana.log"
  export FAKE_ASANA_ADDPROJECT="$CASE_DIR/addproject.log"
  export FAKE_TASKS_LOG="$CASE_DIR/tasks-axi.log"
  : > "$FAKE_TASKS_LOG"  # so a "tasks-axi was never called" assertion reads a real empty file
  unset FAKE_ASANA_FAIL FAKE_ASANA_ENDLESS
  printf '[]\n' > "$FAKE_ASANA_STORE"
}

# Run the script from <dir> with the scratch home and fake Asana target.
run_file() {  # <cwd> <args...>
  local cwd=$1
  shift
  (
    cd "$cwd" || exit 1
    FM_HOME="$HOME_DIR" \
    FM_ASANA_API="http://asana.invalid/api/1.0" \
    FM_ASANA_PROJECT="$PROJECT_GID" \
    FM_ASANA_SECTION="$SECTION_GID" \
    ASANA_ACCESS_TOKEN=fake-token \
    "$ROOT/bin/fm-file-finding.sh" "$@"
  )
}

FINDING=(--title "pool key is never refreshed"
  --where "src/pool.ts:42"
  --why "the cached key outlives its lease, so a second caller gets a dead slot"
  --expected "the lease renewal should invalidate the cache")
STD_ARGS=(--blocking no "${FINDING[@]}")

record_file() { printf '%s/state/findings/%s.json' "$HOME_DIR" "$1"; }
only_record() { find "$HOME_DIR/state/findings" -name '*.json' 2>/dev/null | head -1; }

# --- tests ------------------------------------------------------------------

test_script_parses() {
  bash -n "$ROOT/bin/fm-file-finding.sh" || fail "bin/fm-file-finding.sh fails bash -n"
  pass "fm-file-finding.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-file-finding.sh" --help)
  assert_contains "$help" "usage error or a refused blocker." \
    "fm-file-finding.sh --help omitted its header terminator"
  pass "fm-file-finding.sh: --help renders the complete header"
}

# The rule's one question, made mechanical. A blocker must not become a filed-and-
# forgotten card: the script refuses, names the escalation path, files nothing, and
# leaves no record behind to be flushed later.
test_blocker_is_refused_not_filed() {
  local out rc=0
  new_case blocker
  out=$(run_file "$PROJ_DIR" "${FINDING[@]}" --blocking yes 2>&1) || rc=$?
  expect_code 2 "$rc" "a blocking finding must be refused"
  assert_contains "$out" "needs-decision" "the refusal must name the escalation path"
  assert_absent "$HOME_DIR/state/findings" "a refused blocker must leave no record to flush"
  assert_absent "$FAKE_ASANA_LOG" "a refused blocker must not call the tracker"
  pass "fm-file-finding.sh: --blocking yes is refused, files nothing, points at escalation"
}

test_blocking_flag_is_required() {
  local out rc=0
  new_case no_blocking_flag
  out=$(run_file "$PROJ_DIR" \
    --title t --where "a.ts:1" --why w --expected e 2>&1) || rc=$?
  expect_code 2 "$rc" "the blocking question must be required"
  assert_contains "$out" "--blocking is required" "the error must name the missing flag"
  pass "fm-file-finding.sh: --blocking is required"
}

# The product route: one card, in the configured project, moved into the configured
# section, carrying all four things the rule demands plus the hidden dedupe trailer.
test_product_finding_files_a_card_into_the_section() {
  local out key notes
  new_case product
  out=$(run_file "$PROJ_DIR" "${STD_ARGS[@]}") || fail "filing a product finding failed: $out"
  assert_contains "$out" "filed: " "the verdict line must report the filed card"
  assert_grep "POST http://asana.invalid/api/1.0/tasks?opt_fields=permalink_url" \
    "$FAKE_ASANA_LOG" "the card must be created through POST /tasks"
  assert_grep "\"section\": \"$SECTION_GID\"" "$FAKE_ASANA_ADDPROJECT" \
    "the card must be moved into the configured Triage section"
  notes=$(jq -r '.[0].notes' "$FAKE_ASANA_STORE")
  assert_contains "$notes" "the cached key outlives its lease" "the notes must carry WHY"
  assert_contains "$notes" "Where: src/pool.ts:42" "the notes must carry WHERE"
  assert_contains "$notes" "Expected instead: the lease renewal" "the notes must carry EXPECTED"
  assert_contains "$notes" "[fm-finding: " "the notes must carry the dedupe trailer"
  key=$(basename "$(only_record)" .json)
  assert_grep '"state": "filed"' "$(record_file "$key")" "the local record must say filed"
  pass "fm-file-finding.sh: a product finding becomes one Triage card with all four things"
}

# The dedupe that matters: the SECOND attempt has no local record to short-circuit on, so
# it must find the card by scanning the tracker for the trailer and create nothing.
test_refiling_after_losing_the_local_record_creates_no_second_card() {
  local out creates
  new_case dedupe
  run_file "$PROJ_DIR" "${STD_ARGS[@]}" >/dev/null || fail "first filing failed"
  rm -rf "$HOME_DIR/state/findings"
  out=$(run_file "$PROJ_DIR" "${STD_ARGS[@]}") || fail "second filing failed: $out"
  assert_contains "$out" "already-filed: " "the second attempt must report the existing card"
  creates=$(grep -c "POST http://asana.invalid/api/1.0/tasks?opt_fields" "$FAKE_ASANA_LOG")
  [ "$creates" -eq 1 ] || fail "expected exactly 1 card created, got $creates"
  [ "$(jq 'length' "$FAKE_ASANA_STORE")" -eq 1 ] || fail "the tracker holds more than one card"
  pass "fm-file-finding.sh: re-filing after the local record is gone creates no second card"
}

# "Cannot verify" is not "no match". When the scan runs out of pages without a verdict the
# script must defer rather than risk a duplicate.
test_unverifiable_scan_defers_instead_of_duplicating() {
  local out
  new_case scan_cap
  export FAKE_ASANA_ENDLESS=1
  out=$(FM_FINDING_SCAN_PAGES=2 run_file "$PROJ_DIR" "${STD_ARGS[@]}") ||
    fail "an unverifiable scan must not fail the task"
  assert_contains "$out" "deferred: " "an unverifiable scan must defer"
  assert_no_grep "POST http://asana.invalid/api/1.0/tasks?opt_fields" "$FAKE_ASANA_LOG" \
    "the script must not create a card it could not first rule out"
  pass "fm-file-finding.sh: an unverifiable scan defers instead of duplicating"
}

# A tracker outage must never fail the task and never lose the finding: the record is
# written before the network call, the verdict is `deferred:`, and flush re-files it.
test_tracker_outage_defers_and_flush_recovers() {
  local out key flushed
  new_case outage
  export FAKE_ASANA_FAIL=1
  out=$(run_file "$PROJ_DIR" "${STD_ARGS[@]}") || fail "a tracker outage must not fail the task"
  assert_contains "$out" "deferred: " "an unreachable tracker must defer, not fail"
  key=$(basename "$(only_record)" .json)
  assert_grep '"state": "pending"' "$(record_file "$key")" "the finding must be held locally"
  assert_grep 'the cached key outlives its lease' "$(record_file "$key")" \
    "the held record must carry the finding itself, not just a marker"
  unset FAKE_ASANA_FAIL
  flushed=$(FM_HOME="$HOME_DIR" FM_ASANA_API="http://asana.invalid/api/1.0" \
    FM_ASANA_PROJECT="$PROJECT_GID" FM_ASANA_SECTION="$SECTION_GID" \
    ASANA_ACCESS_TOKEN=fake-token "$ROOT/bin/fm-file-finding.sh" flush)
  assert_contains "$flushed" "filed: " "flush must re-file the held finding"
  assert_grep '"state": "filed"' "$(record_file "$key")" "flush must mark the record filed"
  [ "$(jq 'length' "$FAKE_ASANA_STORE")" -eq 1 ] || fail "flush must file exactly one card"
  pass "fm-file-finding.sh: an unreachable tracker defers, holds the finding, and flush recovers it"
}

# The split. A finding about firstmate's own tooling goes to this home's backlog and must
# not touch the user's product board at all - asserted on the ABSENCE of any Asana call.
test_fleet_finding_goes_to_the_backlog_and_never_to_asana() {
  local out
  new_case fleet
  out=$(run_file "$PROJ_DIR" --scope fleet "${STD_ARGS[@]}") ||
    fail "filing a fleet finding failed: $out"
  assert_contains "$out" "filed: backlog" "a fleet finding must report a backlog task"
  assert_absent "$FAKE_ASANA_LOG" "a firstmate-internal finding must never reach Asana"
  assert_grep "[fm-finding: " "$HOME_DIR/data/backlog.md" \
    "the backlog task must carry the dedupe trailer"
  assert_grep "the cached key outlives its lease" "$HOME_DIR/data/backlog.md" \
    "the backlog task must carry WHY"
  pass "fm-file-finding.sh: a fleet finding goes to the backlog, never to the product board"
}

test_fleet_refiling_creates_one_backlog_task() {
  local out adds
  new_case fleet_dedupe
  run_file "$PROJ_DIR" --scope fleet "${STD_ARGS[@]}" >/dev/null || fail "first filing failed"
  rm -rf "$HOME_DIR/state/findings"
  out=$(run_file "$PROJ_DIR" --scope fleet "${STD_ARGS[@]}") || fail "second filing failed: $out"
  assert_contains "$out" "already-filed: " "the second attempt must find the existing task"
  adds=$(grep -c '^add ' "$FAKE_TASKS_LOG")
  [ "$adds" -eq 1 ] || fail "expected exactly 1 backlog task, got $adds"
  pass "fm-file-finding.sh: re-filing a fleet finding creates one backlog task"
}

# Routing without --scope: a worktree of firstmate's own repo is a fleet finding, any
# other repo is a product one. This is what makes the one-line rule work by default.
test_scope_is_detected_from_the_repository() {
  new_case autoscope
  run_file "$ROOT" "${STD_ARGS[@]}" >/dev/null || fail "filing from the firstmate repo failed"
  assert_absent "$FAKE_ASANA_LOG" "a finding raised inside firstmate's own repo must not reach Asana"
  assert_grep "[fm-finding: " "$HOME_DIR/data/backlog.md" "it must land in the backlog instead"

  new_case autoscope_product
  run_file "$PROJ_DIR" "${STD_ARGS[@]}" >/dev/null || fail "filing from a project repo failed"
  assert_present "$FAKE_ASANA_LOG" "a finding raised in a project repo must reach the product board"
  assert_absent "$HOME_DIR/data/backlog.md" "it must not land in firstmate's backlog"
  pass "fm-file-finding.sh: scope is detected from the repository the finding is about"
}

# A filed finding is a work record, not authorized work: it must land held, so firstmate's
# "dispatch whatever is Queued and unblocked" sweep cannot turn it into a crew before a
# human has read it. This is the backlog's equivalent of the Asana Triage section.
test_backlog_finding_lands_held() {
  new_case held
  run_file "$PROJ_DIR" --scope fleet "${STD_ARGS[@]}" >/dev/null || fail "filing failed"
  assert_grep "hold: unreviewed finding" "$HOME_DIR/data/backlog.md" \
    "a filed finding must not be dispatchable before a human has triaged it"
  assert_grep "hold finding-xx --reason" "$FAKE_TASKS_LOG" "the hold must go through tasks-axi"
  pass "fm-file-finding.sh: a fleet finding lands held, not dispatchable"
}

# A home whose tasks-axi is missing, too old, or opted out with backlog-backend=manual must
# still get its finding recorded - holding one hostage to a tool version is the failure this
# whole rule exists to stop. AGENTS.md section 9 sanctions hand-editing exactly then.
test_manual_backend_still_records_the_finding() {
  local out
  new_case manual
  mkdir -p "$HOME_DIR/config"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  out=$(run_file "$PROJ_DIR" --scope fleet "${STD_ARGS[@]}") || fail "filing failed: $out"
  assert_contains "$out" "filed: backlog" "a manual-backend home must still file the finding"
  assert_no_grep "add pool key is never refreshed" "$FAKE_TASKS_LOG" \
    "a manual-backend home must not call tasks-axi add"
  assert_grep "the cached key outlives its lease" "$HOME_DIR/data/backlog.md" \
    "the hand-written row must carry the finding"
  assert_grep "hold: unreviewed finding" "$HOME_DIR/data/backlog.md" \
    "the hand-written row must be held like the tasks-axi one"
  assert_grep "[fm-finding: " "$HOME_DIR/data/backlog.md" \
    "the hand-written row must carry the dedupe trailer"
  pass "fm-file-finding.sh: a manual-backend home still records the finding, held"
}

# A 2xx that is not the task list - a proxy interstitial, a truncated read - is "could not
# look", never "looked, nothing there". Reading it as the latter creates a duplicate card.
test_unreadable_scan_payload_defers() {
  local out
  new_case unreadable
  run_file "$PROJ_DIR" "${STD_ARGS[@]}" >/dev/null || fail "first filing failed"
  rm -rf "$HOME_DIR/state/findings"
  printf '<html>proxy interstitial</html>' > "$FAKE_ASANA_STORE"
  out=$(run_file "$PROJ_DIR" "${STD_ARGS[@]}") || fail "an unreadable payload must not fail the task"
  assert_contains "$out" "deferred: " "an unreadable scan payload must defer"
  assert_contains "$out" "unreadable payload" "the deferral must say what went wrong"
  pass "fm-file-finding.sh: an unreadable 2xx scan payload defers instead of duplicating"
}

# firstmate reviews a crew's diff from its own checkout, so the routing probe must follow
# the repository the finding is ABOUT, not the caller's cwd - otherwise every product
# finding firstmate itself raises is filed into the fleet backlog and no human ever sees it.
test_routing_follows_the_repo_the_finding_is_about() {
  new_case subject_repo
  mkdir -p "$HOME_DIR/projects"
  cp -r "$PROJ_DIR" "$HOME_DIR/projects/acme"
  run_file "$ROOT" --repo acme "${STD_ARGS[@]}" >/dev/null ||
    fail "filing a project finding from the firstmate checkout failed"
  assert_present "$FAKE_ASANA_LOG" \
    "a finding about a project must reach the product board even when filed from firstmate's own checkout"
  assert_absent "$HOME_DIR/data/backlog.md" "it must not land in firstmate's backlog"
  pass "fm-file-finding.sh: routing follows the repository the finding is about, not the cwd"
}

# Nobody has to remember `flush`: the next successful filing drains what an outage held.
test_a_later_filing_drains_what_the_outage_held() {
  local out
  new_case autodrain
  export FAKE_ASANA_FAIL=1
  run_file "$PROJ_DIR" "${STD_ARGS[@]}" >/dev/null || fail "the deferral must not fail the task"
  unset FAKE_ASANA_FAIL
  out=$(run_file "$PROJ_DIR" --blocking no --title "second defect" --where "src/b.ts:9" \
    --why "it double-frees" --expected "one free") || fail "the second filing failed: $out"
  [ "$(jq 'length' "$FAKE_ASANA_STORE")" -eq 2 ] ||
    fail "expected the held finding to be filed alongside the new one, got $(jq 'length' "$FAKE_ASANA_STORE")"
  [ "$(grep -l '"state": "pending"' "$HOME_DIR/state/findings"/*.json 2>/dev/null | wc -l)" -eq 0 ] ||
    fail "a finding is still held after the tracker came back"
  pass "fm-file-finding.sh: a later successful filing drains what an outage held"
}

# The same defect reported with different wording for WHY is the same finding: the key is
# built from title + where + repo, so a resumed crew re-filing it does not duplicate.
test_key_ignores_reworded_why() {
  local out
  new_case rewording
  run_file "$PROJ_DIR" "${STD_ARGS[@]}" >/dev/null || fail "first filing failed"
  rm -rf "$HOME_DIR/state/findings"
  out=$(run_file "$PROJ_DIR" --blocking no \
    --title "pool key is never refreshed" --where "src/pool.ts:42" \
    --why "completely different wording for the same defect" \
    --expected "something else entirely") || fail "re-filing failed: $out"
  assert_contains "$out" "already-filed: " "a reworded why must not create a second card"
  pass "fm-file-finding.sh: the dedupe key survives a reworded explanation"
}

test_script_parses
test_help_includes_entire_header
test_blocker_is_refused_not_filed
test_blocking_flag_is_required
test_product_finding_files_a_card_into_the_section
test_refiling_after_losing_the_local_record_creates_no_second_card
test_unverifiable_scan_defers_instead_of_duplicating
test_tracker_outage_defers_and_flush_recovers
test_fleet_finding_goes_to_the_backlog_and_never_to_asana
test_fleet_refiling_creates_one_backlog_task
test_scope_is_detected_from_the_repository
test_backlog_finding_lands_held
test_manual_backend_still_records_the_finding
test_unreadable_scan_payload_defers
test_routing_follows_the_repo_the_finding_is_about
test_a_later_filing_drains_what_the_outage_held
test_key_ignores_reworded_why
