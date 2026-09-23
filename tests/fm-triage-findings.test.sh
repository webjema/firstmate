#!/usr/bin/env bash
# Behavior tests for bin/fm-triage-findings.sh, the mechanical half of the finding drain.
#
# The drain's whole contract is the tasks-axi hold state machine - list a verify hold, clear
# it, close it, or turn it into a captain hold - so this suite exercises the REAL tasks-axi
# rather than a stub of it: a stub would only prove the stub. It skips cleanly where the tool
# is absent or too old, exactly like tests/fm-backlog-handoff.test.sh, which delegates to the
# same backend. Findings are seeded through bin/fm-file-finding.sh, so the queue under test is
# the one the filer really writes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (the drain delegates to it)"; exit 0; }
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$ROOT/bin/fm-tasks-axi-lib.sh"
fm_tasks_axi_compatible || { echo "skip: tasks-axi too old for the backend the drain needs"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-triage-findings)
FILE="$ROOT/bin/fm-file-finding.sh"
DRAIN="$ROOT/bin/fm-triage-findings.sh"
GENERIC="unreviewed finding - triage before dispatching"

# A scratch home with a firstmate-like repo to file fleet findings from. Each case gets its
# own backlog so the tasks-axi state of one test never leaks into another.
new_case() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
  BL="$HOME_DIR/data/backlog.md"
}

# File one fleet finding and print the backlog id the filer minted for it.
seed() {  # <title> <where> <why> <expected> [--needs X --question Y]
  local title=$1 where=$2 why=$3 expected=$4; shift 4
  local out
  out=$(FM_HOME="$HOME_DIR" "$FILE" --scope fleet --blocking no \
    --title "$title" --where "$where" --why "$why" --expected "$expected" "$@") ||
    { echo "seed failed: $out" >&2; return 1; }
  printf '%s' "$out" | sed -n 's/^filed: backlog //p' | sed 's/ \[.*//'
}

axi() { tasks-axi "$@" --file "$BL"; }
held_of() { axi show "$1" 2>/dev/null | awk -v f="  $2: " 'index($0,f)==1{v=substr($0,length(f)+1);sub(/^"/,"",v);sub(/"$/,"",v);print v;exit}'; }

# --- tests ------------------------------------------------------------------

test_script_parses() {
  bash -n "$DRAIN" || fail "bin/fm-triage-findings.sh fails bash -n"
  pass "fm-triage-findings.sh: bash -n succeeds"
}

test_help_documents_the_interface() {
  local help rc
  help=$("$DRAIN" --help); rc=$?
  [ "$rc" -eq 0 ] || fail "--help must exit 0, got $rc"
  # The contract --help must convey: the three verbs and the four verdicts. These are the
  # runtime interface, not header prose - a reword of the surrounding sentences must not
  # break this, but dropping a verb or verdict from the documented surface must.
  local tok
  for tok in list apply migrate real fixed obsolete decision; do
    assert_contains "$help" "$tok" "--help must document '$tok'"
  done
  pass "fm-triage-findings.sh: --help documents every verb and verdict"
}

# list emits one JSON object per verify-held finding, and ONLY verify holds: a captain
# question and a foreign parked hold are both skipped, so the drain never lists a finding a
# human is meant to answer.
test_list_emits_only_verify_holds_as_jsonl() {
  new_case list_verify
  local v c
  v=$(seed "verify one" "bin/a.sh:1" "a breaks" "a works")
  c=$(seed "captain one" "bin/b.sh:2" "b needs a call" "b decided" \
    --needs decision --question "which way to build b?")
  # a foreign parked hold this drain must not touch
  local f; f=$(seed "foreign one" "bin/c.sh:3" "c parked elsewhere" "c ok")
  axi hold "$f" --reason "external: waiting on upstream" --kind parked >/dev/null

  local out; out=$("$DRAIN" list --file "$BL")
  # every emitted line is valid JSON
  printf '%s\n' "$out" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 || fail "list emitted a non-JSON line: $line"
  done
  assert_contains "$out" "\"id\":\"$v\"" "the verify-held finding must be listed"
  case "$out" in
    *"\"id\":\"$c\""*) fail "a captain-held finding must not be listed" ;;
    *"\"id\":\"$f\""*) fail "a foreign parked hold must not be listed" ;;
  esac
  local where; where=$(printf '%s' "$out" | jq -r "select(.id==\"$v\") | .where")
  [ "$where" = "bin/a.sh:1" ] || fail "list must extract the file:line (got '$where')"
  pass "fm-triage-findings.sh: list emits only verify holds, as valid JSONL with the file:line"
}

test_list_respects_limit() {
  new_case list_limit
  local i
  for i in 1 2 3; do seed "finding $i" "bin/f$i.sh:$i" "w$i" "e$i" >/dev/null; done
  local n; n=$("$DRAIN" list --limit 2 --file "$BL" | grep -c '"id"')
  [ "$n" -eq 2 ] || fail "list --limit 2 must emit exactly 2 records (got $n)"
  pass "fm-triage-findings.sh: list caps the batch at --limit"
}

# real on a mechanical finding clears the hold: it becomes dispatchable work. And it is
# idempotent - a second apply reports already-applied and touches nothing.
test_apply_real_dispatches_and_is_idempotent() {
  new_case apply_real
  local id; id=$(seed "typo in help" "bin/y.sh:9" "help says recieve" "receive")
  local out; out=$("$DRAIN" apply "$id" --verdict real --evidence "typo present at bin/y.sh:9" --file "$BL")
  assert_contains "$out" "dispatched: $id" "a real finding must be dispatched"
  [ "$(held_of "$id" held)" = no ] || fail "a dispatched finding must no longer be held"
  local again; again=$("$DRAIN" apply "$id" --verdict real --evidence "again" --file "$BL")
  assert_contains "$again" "already-applied" "re-applying real must be an idempotent no-op"
  pass "fm-triage-findings.sh: apply real dispatches, idempotently"
}

# fixed and obsolete close the finding WITH the evidence, and closing is idempotent.
test_apply_fixed_closes_with_evidence() {
  new_case apply_fixed
  local id; id=$(seed "pipe untracked" "bin/z.sh:5" "pipe dir not ignored" "ignored")
  local out; out=$("$DRAIN" apply "$id" --verdict fixed --evidence "gitignored at .gitignore:40" --file "$BL")
  assert_contains "$out" "closed: $id [fixed]" "a fixed finding must close"
  [ "$(held_of "$id" state)" = "done" ] || fail "a fixed finding must be marked done"
  assert_grep "gitignored at .gitignore:40" "$BL" "the evidence must be recorded on the closed finding"
  local again; again=$("$DRAIN" apply "$id" --verdict fixed --evidence "again" --file "$BL")
  assert_contains "$again" "already-applied" "re-closing must be an idempotent no-op"
  pass "fm-triage-findings.sh: apply fixed closes with the evidence, idempotently"
}

test_apply_obsolete_closes() {
  new_case apply_obsolete
  local id; id=$(seed "gone code" "bin/old.sh:1" "refers to deleted code" "n/a")
  local out; out=$("$DRAIN" apply "$id" --verdict obsolete --evidence "bin/old.sh deleted in the meantime" --file "$BL")
  assert_contains "$out" "closed: $id [obsolete]" "an obsolete finding must close"
  [ "$(held_of "$id" state)" = "done" ] || fail "an obsolete finding must be marked done"
  pass "fm-triage-findings.sh: apply obsolete closes the finding"
}

# decision is the drain's own escalation: it re-holds the finding for the captain WITH the
# question, and the question is required - a captain hold with no question is the silent row.
test_apply_decision_escalates_with_question() {
  new_case apply_decision
  local id; id=$(seed "direction too long" "data/directions/x.md:1" "over the cap" "trim it")
  local rc=0 out
  out=$("$DRAIN" apply "$id" --verdict decision --evidence "verified over cap" --file "$BL" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "decision with no --question must be refused"
  assert_contains "$out" "requires --question" "the refusal must name the missing question"
  [ "$(held_of "$id" hold_kind)" = parked ] || fail "a refused decision must leave the finding on its verify hold"

  out=$("$DRAIN" apply "$id" --verdict decision --evidence "verified over cap" \
    --question "trim to 450 words or raise the cap?" --file "$BL")
  assert_contains "$out" "escalated: $id [decision]" "a decision must escalate to the captain"
  [ "$(held_of "$id" hold_kind)" = captain ] || fail "an escalated decision must land on a captain hold"
  case "$(held_of "$id" hold_reason)" in
    *"trim to 450 words"*) : ;;
    *) fail "the captain hold reason must carry the question" ;;
  esac
  pass "fm-triage-findings.sh: apply decision escalates with the question, and needs one"
}

# THE SAFETY FLOOR: a finding whose own text is destructive, irreversible, or security-
# sensitive escalates to the captain even on a real verdict - the machine never starts it.
test_safety_floor_escalates_dangerous_findings_on_real() {
  new_case safety_floor
  local danger safe
  danger=$(seed "cleanup force-pushes rewritten history" "bin/deploy.sh:20" \
    "runs git push --force to main after reset --hard, discarding work" "guarded fast-forward only")
  safe=$(seed "typo in comment" "bin/q.sh:2" "says teh" "the")

  local out; out=$("$DRAIN" apply "$danger" --verdict real --evidence "confirmed force push" --file "$BL")
  assert_contains "$out" "escalated: $danger" "a dangerous finding must escalate, not dispatch"
  [ "$(held_of "$danger" held)" = yes ] || fail "a dangerous finding must stay held"
  [ "$(held_of "$danger" hold_kind)" = captain ] || fail "a dangerous finding must land on a captain hold"

  out=$("$DRAIN" apply "$safe" --verdict real --evidence "typo present" --file "$BL")
  assert_contains "$out" "dispatched: $safe" "a benign finding must still dispatch"
  [ "$(held_of "$safe" held)" = no ] || fail "a benign real finding must be dispatched"
  pass "fm-triage-findings.sh: the safety floor escalates dangerous findings, dispatches benign ones"
}

# A finding that is no longer on a verify hold was already triaged; the drain refuses to
# re-open it, so a stale batch can never resurrect resolved work.
test_apply_refuses_a_finding_not_on_a_verify_hold() {
  new_case refuse_nonverify
  local id rc=0 out
  id=$(seed "real question" "bin/r.sh:1" "needs a call" "decided" \
    --needs decision --question "which way?")
  out=$("$DRAIN" apply "$id" --verdict real --evidence "x" --file "$BL" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "applying to a captain-held finding must be refused"
  assert_contains "$out" "not on a verify hold" "the refusal must say why"
  pass "fm-triage-findings.sh: apply refuses a finding that is not on a verify hold"
}

# Closing (fixed/obsolete) must honour the same verify-hold gate as real/decision: a captain
# hold is a human's open question, and closing it fixed/obsolete would silently drop that
# question. The drain must refuse and leave the question open.
test_apply_close_refuses_a_captain_hold() {
  new_case close_captain
  local id rc out verdict
  for verdict in fixed obsolete; do
    id=$(seed "open question $verdict" "bin/q.sh:1" "needs a call" "decided" \
      --needs decision --question "which way to build it?")
    rc=0
    out=$("$DRAIN" apply "$id" --verdict "$verdict" --evidence "x" --file "$BL" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "closing a captain-held finding [$verdict] must be refused"
    assert_contains "$out" "not on a verify hold" "the [$verdict] refusal must say why"
    [ "$(held_of "$id" hold_kind)" = captain ] || fail "a refused close must leave the captain hold in place [$verdict]"
    [ "$(held_of "$id" state)" != "done" ] || fail "a refused close must not close the finding [$verdict]"
  done
  pass "fm-triage-findings.sh: fixed/obsolete refuse to close a captain hold"
}

# A tracker failure must leave the finding exactly as it was - never dropped. A read-only
# backlog DIRECTORY makes the tasks-axi write fail (it writes via a temp file + rename, which
# needs to create and unlink inside the dir); the finding must stay on its verify hold.
test_apply_failure_leaves_the_finding_held() {
  new_case apply_fails_held
  local id; id=$(seed "some finding" "bin/s.sh:1" "w" "e")
  local dir; dir=$(dirname "$BL")
  chmod 0555 "$dir"
  local rc=0 out
  out=$("$DRAIN" apply "$id" --verdict real --evidence "x" --file "$BL" 2>&1) || rc=$?
  chmod 0755 "$dir"
  [ "$rc" -ne 0 ] || fail "a failed apply must exit non-zero"
  assert_contains "$out" "stays held" "a failed apply must say the finding stays held"
  [ "$(held_of "$id" hold_kind)" = parked ] || fail "a failed apply must leave the finding on its verify hold"
  pass "fm-triage-findings.sh: a failed apply leaves the finding held, never dropped"
}

# migrate re-labels a pre-flip queue onto the verify hold, leaves a real captain question
# alone, and is idempotent.
test_migrate_flips_generic_holds_only_and_is_idempotent() {
  new_case migrate
  local gen real
  gen=$(seed "old generic finding" "bin/g.sh:1" "w" "e")
  real=$(seed "real captain question" "bin/h.sh:2" "needs call" "decided" \
    --needs decision --question "which way?")
  # put the generic finding back into the pre-flip state the old filer wrote
  axi hold "$gen" --reason "$GENERIC" --kind captain >/dev/null
  [ "$(held_of "$gen" hold_kind)" = captain ] || fail "setup: generic finding should be captain-held"

  local out; out=$("$DRAIN" migrate --file "$BL")
  assert_contains "$out" "migrated: 1 finding" "migrate must move the one generic hold"
  [ "$(held_of "$gen" hold_kind)" = parked ] || fail "the generic finding must move to the verify hold"
  case "$(held_of "$gen" hold_reason)" in verify:*) : ;; *) fail "the migrated reason must be a verify reason" ;; esac
  [ "$(held_of "$real" hold_kind)" = captain ] || fail "a real captain question must be left on its captain hold"

  out=$("$DRAIN" migrate --file "$BL")
  assert_contains "$out" "migrated: 0 finding" "a second migrate must find nothing left"
  pass "fm-triage-findings.sh: migrate flips only the generic holds, leaves real questions, idempotent"
}

test_backend_unavailable_is_a_hard_error() {
  new_case no_backend
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  local rc=0 out
  out=$(FM_HOME="$HOME_DIR" "$DRAIN" list 2>&1) || rc=$?
  expect_code 2 "$rc" "the drain must refuse when its backend is opted out"
  assert_contains "$out" "backend unavailable" "the error must name the missing backend"
  pass "fm-triage-findings.sh: an unavailable backend is a hard error, not a silent skip"
}

test_script_parses
test_help_documents_the_interface
test_list_emits_only_verify_holds_as_jsonl
test_list_respects_limit
test_apply_real_dispatches_and_is_idempotent
test_apply_fixed_closes_with_evidence
test_apply_obsolete_closes
test_apply_decision_escalates_with_question
test_safety_floor_escalates_dangerous_findings_on_real
test_apply_refuses_a_finding_not_on_a_verify_hold
test_apply_close_refuses_a_captain_hold
test_apply_failure_leaves_the_finding_held
test_migrate_flips_generic_holds_only_and_is_idempotent
test_backend_unavailable_is_a_hard_error
