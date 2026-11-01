#!/usr/bin/env bash
# Behavior tests for the product-board half of the finding lifecycle: the Asana Triage drain
# (bin/fm-triage-findings.sh --asana) and close-on-merge (bin/fm-asana-close-fixed.sh). Both
# run against the fake Asana in tests/asana-helpers.sh; no test reaches the real API.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/asana-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/asana-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-asana-triage)
DRAIN="$ROOT/bin/fm-triage-findings.sh"
CLOSE="$ROOT/bin/fm-asana-close-fixed.sh"
# Made-up gids, long enough for the PR-body parser.
P=1000000000001
TRIAGE=1000000000002
QUEUE=1000000000003
CAPTAIN=1000000000004
OTHER_BOARD=1000000000009

new_case() {  # <name> [--no-queue]
  local fakebin
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
  fakebin=$(fm_fakebin "$CASE_DIR")
  install_fake_curl "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
cat "$FAKE_GH_PR"
SH
  chmod +x "$fakebin/gh"
  export PATH="$fakebin:$PATH"
  export FAKE_GH_PR="$CASE_DIR/pr.json"
  reset_fake_asana "$CASE_DIR"
  jq -n --arg p "$P" --arg t "$TRIAGE" --arg q "$QUEUE" --arg c "$CAPTAIN" --arg nq "${2:-}" \
    '[{gid:$t,name:"Triage",project:$p}, {gid:$c,name:"Needs captain",project:$p}]
     + (if $nq == "--no-queue" then [] else [{gid:$q,name:"Agent queue",project:$p}] end)' \
    > "$FAKE_ASANA_SECTIONS"
}

card() {  # <gid> <section> <name> [completed] [project]
  jq --arg g "$1" --arg s "$2" --arg n "$3" --argjson closed "${4:-false}" --arg p "${5:-$P}" \
    '. + [{gid:$g, name:$n, project:$p, section:$s, completed:$closed, tags:["sev:S1"],
           notes:("Issue\n" + $n + " misbehaves\nWhere: src/x.ts:1\nExpected: it behaves\nRepository: acme")}]' \
    "$FAKE_ASANA_STORE" > "$FAKE_ASANA_STORE.tmp" && mv "$FAKE_ASANA_STORE.tmp" "$FAKE_ASANA_STORE"
}
field() { jq -r --arg g "$1" ".[] | select(.gid == \$g) | .$2" "$FAKE_ASANA_STORE"; }
comments_on() { jq -s --arg g "$1" '[.[] | select(.gid == $g)] | length' "$FAKE_ASANA_STORIES" 2>/dev/null || echo 0; }

asana_env() {
  FM_HOME="$HOME_DIR" FM_ASANA_API="http://asana.invalid/api/1.0" FM_ASANA_PROJECT="$P" \
    FM_ASANA_SECTION="$TRIAGE" ASANA_ACCESS_TOKEN=fake-token "$@"
}
drain() { asana_env "$DRAIN" "$@" --asana; }

# --- tests ------------------------------------------------------------------

test_list_emits_only_open_triage_cards() {
  local out
  new_case list
  card 1000000000101 "$TRIAGE" "waiting card"
  card 1000000000102 "$TRIAGE" "closed card" true
  card 1000000000103 "$QUEUE" "dispatched card"
  out=$(drain list) || fail "list --asana failed: $out"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "list must emit only the open Triage card, got: $out"
  [ "$(printf '%s' "$out" | jq -r '.id + " " + .severity + " " + .where')" = "1000000000101 S1 src/x.ts:1" ] ||
    fail "the record must carry the card's id, severity and where, got: $out"
  pass "fm-triage-findings.sh --asana: list emits only open Triage cards"
}

test_apply_moves_closes_and_escalates() {
  local out
  new_case apply
  card 1000000000201 "$TRIAGE" "real card"
  card 1000000000202 "$TRIAGE" "the purge does a force push"
  card 1000000000203 "$TRIAGE" "fixed card"
  card 1000000000204 "$TRIAGE" "repeat card"
  card 1000000000205 "$TRIAGE" "original card"
  card 1000000000206 "$QUEUE" "already triaged card"

  drain apply 1000000000201 --verdict real --evidence "src/x.ts:1 still fails" >/dev/null ||
    fail "apply real failed"
  [ "$(field 1000000000201 section)" = "$QUEUE" ] || fail "a real card must move to the agent queue"
  out=$(drain apply 1000000000201 --verdict real --evidence "again") || fail "a re-apply must not fail"
  assert_contains "$out" "already-applied" "a re-applied real verdict must be a no-op"

  drain apply 1000000000202 --verdict real --evidence "still there" >/dev/null || fail "apply real (danger) failed"
  [ "$(field 1000000000202 section)" = "$CAPTAIN" ] ||
    fail "the safety floor must move a dangerous real card to the captain, not the queue"

  drain apply 1000000000203 --verdict fixed --evidence "src/x.ts:9 fixes it" >/dev/null || fail "apply fixed failed"
  [ "$(field 1000000000203 completed)" = true ] || fail "a fixed card must be completed"

  drain apply 1000000000204 --verdict duplicate --duplicate-of 1000000000205 --evidence "same cause" >/dev/null ||
    fail "apply duplicate failed"
  [ "$(field 1000000000204 completed)" = true ] || fail "a duplicate card must be completed"
  [ "$(comments_on 1000000000205)" -eq 1 ] || fail "a duplicate's text must be commented on the card it repeats"
  [ "$(field 1000000000205 completed)" = false ] || fail "the card a duplicate repeats must stay open"

  card 1000000000207 "$TRIAGE" "merged repeat card"
  jq -nc '{gid:"1000000000207", text:"Reported again: the fix is to drop table users"}' >> "$FAKE_ASANA_STORIES"
  drain apply 1000000000207 --verdict real --evidence "still there" >/dev/null || fail "apply real (danger in comment) failed"
  [ "$(field 1000000000207 section)" = "$CAPTAIN" ] ||
    fail "the safety floor must read the comments that dedup merged into a card"

  card 1000000000208 "$TRIAGE" "repeat of a closed card"
  out=$(drain apply 1000000000208 --verdict duplicate --duplicate-of 1000000000203 --evidence "same" 2>&1) &&
    fail "closing into a closed card must be refused: $out"
  [ "$(field 1000000000208 completed)" = false ] || fail "a refused duplicate must leave the card open"

  out=$(drain apply 1000000000206 --verdict fixed --evidence "x" 2>&1) && fail "closing a triaged card must be refused: $out"
  [ "$(field 1000000000206 completed)" = false ] || fail "a refused close must leave the card open"
  pass "fm-triage-findings.sh --asana: apply moves real, escalates danger, closes fixed and duplicates"
}

# Never lose a card: a board with nowhere to put a real card leaves it in Triage.
test_apply_with_no_queue_section_leaves_the_card_in_triage() {
  local rc=0
  new_case no_queue --no-queue
  card 1000000000301 "$TRIAGE" "real card"
  drain apply 1000000000301 --verdict real --evidence "fails" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a board with no queue section must fail the apply"
  [ "$(field 1000000000301 section)" = "$TRIAGE" ] || fail "the card must stay in Triage"
  pass "fm-triage-findings.sh --asana: a board with no queue section leaves the card in Triage"
}

test_close_on_merge_completes_only_the_fixed_cards() {
  local out
  new_case close
  card 1000000000401 "$QUEUE" "fixed by the PR"
  card 1000000000402 "$QUEUE" "only linked"
  card 1000000000403 "$QUEUE" "on a stranger's board" false "$OTHER_BOARD"
  jq -n '{state:"OPEN", body:"Fixes 1000000000401"}' > "$FAKE_GH_PR"
  asana_env "$CLOSE" https://github.com/o/r/pull/1 >/dev/null || fail "close on an open PR failed"
  [ "$(field 1000000000401 completed)" = false ] || fail "an unmerged PR must close nothing"

  card 1000000000404 "$QUEUE" "named in a negation"
  card 1000000000405 "$QUEUE" "linked by the new URL form"
  jq -n '{state:"MERGED", body:"Fixes 1000000000401\nAsana: 1000000000402\nCloses 1000000000403\nThis does not fix 1000000000404.\n- Resolves https://app.asana.com/1/77/project/1000000000001/task/1000000000405"}' > "$FAKE_GH_PR"
  out=$(asana_env "$CLOSE" https://github.com/o/r/pull/1) || fail "close on merge failed: $out"
  [ "$(field 1000000000401 completed)" = true ] || fail "the card the PR fixes must be completed"
  [ "$(field 1000000000402 completed)" = false ] || fail "a card the PR only links must stay open"
  [ "$(field 1000000000403 completed)" = false ] || fail "a card on no configured board must stay open"
  [ "$(field 1000000000404 completed)" = false ] || fail "a negated fix verb must close nothing"
  [ "$(field 1000000000405 completed)" = true ] || fail "the current Asana task URL form must close its card"
  asana_env "$CLOSE" https://github.com/o/r/pull/1 >/dev/null || fail "a second run failed"
  [ "$(comments_on 1000000000401)" -eq 1 ] || fail "a second run must not comment again"
  pass "fm-asana-close-fixed.sh: a merged PR completes the cards it fixes and nothing else"
}

test_list_emits_only_open_triage_cards
test_apply_moves_closes_and_escalates
test_apply_with_no_queue_section_leaves_the_card_in_triage
test_close_on_merge_completes_only_the_fixed_cards
