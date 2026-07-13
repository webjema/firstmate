#!/usr/bin/env bash
# Tests for bin/fm-direction.sh: the per-project direction store that every ship
# and scout brief is built from.
#
# The load-bearing behaviors:
#   (a) brief on a MISSING direction still emits a usable block, and says so
#       explicitly - a crewmate must never confuse "no direction exists" with a
#       broken scaffold
#   (b) brief on a PRESENT direction injects the body, drops the file's H1, and
#       carries the conflict-escalation contract
#   (c) init scaffolds the five required headings and refuses to overwrite
#   (d) check enforces the headings, flags unfilled placeholders, and FAILS on a
#       direction past the hard word cap - the cap is the whole reason the file
#       stays readable, since it is paid on every dispatch
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIRECTION="$ROOT/bin/fm-direction.sh"
TMP_ROOT=$(fm_test_tmproot fm-direction-tests)

# A home with one project clone present, so `list` and bare `check` see it.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/projects/acme"
  printf '%s\n' "$home"
}

run_direction() {
  local home=$1; shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$DIRECTION" "$@"
}

write_direction() {
  local home=$1 project=$2 body=$3
  mkdir -p "$home/data/directions"
  printf '%s\n' "$body" > "$home/data/directions/$project.md"
}

VALID_BODY='# acme - Direction

## Business vision
Sell widgets to procurement teams.

## Architecture direction
Every write goes through a command handler; no lambda touches the store directly.

## Infrastructure direction
CDK only. Nothing is deployed by hand.

## Quality direction
Root-cause fixes only. A symptom patch is a bug.

## Standing decisions
- 2026-07-13 Alpha may lag prod by one release.'

# (a) ------------------------------------------------------------------------
test_brief_on_missing_direction_is_explicit() {
  local home out
  home=$(make_home missing)
  out=$(run_direction "$home" brief acme)

  assert_contains "$out" '# Direction' "missing: still emits the Direction heading"
  assert_contains "$out" 'No direction is on file' "missing: says so explicitly"
  assert_contains "$out" 'needs-decision' "missing: still tells the crew how to escalate"
  pass "brief on a missing direction emits an explicit, usable block"
}

# (b) ------------------------------------------------------------------------
test_brief_injects_body_and_contract() {
  local home out
  home=$(make_home present)
  write_direction "$home" acme "$VALID_BODY"
  out=$(run_direction "$home" brief acme)

  assert_contains "$out" 'no lambda touches the store directly' "present: injects the architecture body"
  assert_contains "$out" 'Alpha may lag prod' "present: injects the standing decisions ledger"
  assert_contains "$out" 'This applies to every change, however small' "present: carries the every-change contract"
  assert_contains "$out" 'direction conflict' "present: carries the conflict-escalation contract"
  # The brief supplies its own heading, so the file's H1 must not be duplicated.
  assert_not_contains "$out" '# acme - Direction' "present: drops the file's own H1"
  pass "brief injects the direction body plus the conflict contract"
}

# (c) ------------------------------------------------------------------------
test_init_scaffolds_and_refuses_overwrite() {
  local home out rc
  home=$(make_home init)

  run_direction "$home" init acme >/dev/null
  out=$(cat "$home/data/directions/acme.md")
  assert_contains "$out" '## Business vision' "init: business vision heading"
  assert_contains "$out" '## Architecture direction' "init: architecture heading"
  assert_contains "$out" '## Infrastructure direction' "init: infrastructure heading"
  assert_contains "$out" '## Quality direction' "init: quality heading"
  assert_contains "$out" '## Standing decisions' "init: standing decisions ledger"

  rc=0
  run_direction "$home" init acme >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "init: must refuse to overwrite an existing direction"
  pass "init scaffolds the five headings and refuses to overwrite"
}

# (d) ------------------------------------------------------------------------
test_check_flags_stub_and_missing_heading() {
  local home out rc
  home=$(make_home check_stub)

  # A freshly scaffolded direction is a stub, not yet a direction.
  run_direction "$home" init acme >/dev/null
  out=$(run_direction "$home" check acme)
  assert_contains "$out" 'DIRECTION_STUB' "check: flags unfilled placeholders"

  # A direction missing a required axis is invalid, and that is a hard failure:
  # a brief built from it would silently omit an axis the captain named.
  write_direction "$home" acme '# acme - Direction

## Business vision
Sell widgets.

## Architecture direction
Command handlers.

## Quality direction
Root-cause only.

## Standing decisions
- none yet'
  rc=0
  out=$(run_direction "$home" check acme) || rc=$?
  [ "$rc" -ne 0 ] || fail "check: a missing required heading must fail"
  assert_contains "$out" 'DIRECTION_INVALID' "check: names the missing heading"
  assert_contains "$out" 'Infrastructure direction' "check: says WHICH heading is missing"
  pass "check flags stubs and hard-fails a missing axis"
}

test_check_hard_fails_past_word_cap() {
  local home out rc filler
  home=$(make_home check_cap)

  # The cap exists because the direction is injected into EVERY brief. A direction
  # that grows into a design doc stops being read, which is the only failure that
  # matters, so past the hard cap this must fail rather than warn.
  filler=$(yes 'words words words words words words words words words words' | head -120)
  write_direction "$home" acme "$VALID_BODY
$filler"

  rc=0
  out=$(run_direction "$home" check acme) || rc=$?
  [ "$rc" -ne 0 ] || fail "check: past the hard word cap must fail, not warn"
  assert_contains "$out" 'DIRECTION_TOO_LONG' "check: names the over-length direction"
  pass "check hard-fails a direction past the word cap"
}

test_check_reports_missing_direction_without_failing() {
  local home out rc
  home=$(make_home check_absent)

  # A project with no direction yet is a normal early state, not an error: it must
  # be reported so firstmate drafts one, but it must not fail the bootstrap sweep.
  rc=0
  out=$(run_direction "$home" check) || rc=$?
  [ "$rc" -eq 0 ] || fail "check: a merely-absent direction must not fail"
  assert_contains "$out" 'DIRECTION_MISSING: acme' "check: reports the project with no direction"
  pass "check reports a missing direction without failing"
}

test_list_reports_projects() {
  local home out
  home=$(make_home list)
  out=$(run_direction "$home" list)
  assert_contains "$out" 'acme' "list: names the project"
  assert_contains "$out" 'NONE' "list: flags the project as having no direction"

  write_direction "$home" acme "$VALID_BODY"
  out=$(run_direction "$home" list)
  assert_contains "$out" 'words' "list: reports the word count once a direction exists"
  pass "list reports each project's direction status"
}

test_brief_on_missing_direction_is_explicit
test_brief_injects_body_and_contract
test_init_scaffolds_and_refuses_overwrite
test_check_flags_stub_and_missing_heading
test_check_hard_fails_past_word_cap
test_check_reports_missing_direction_without_failing
test_list_reports_projects
