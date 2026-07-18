#!/usr/bin/env bash
# Tests for bin/fm-mission.sh: the mission container that mission mode decomposes
# into a task DAG, dispatches, reviews, and ships.
#
# The load-bearing behaviors:
#   (a) new mints an id from the goal, scaffolds the six required sections, records
#       the envelope, and refuses to overwrite an existing mission
#   (b) new validates the envelope up front (positive integers) and honors overrides
#   (c) set-criteria replaces the Acceptance criteria body and drops the placeholder
#   (d) add-task records a DAG member with its blocked-by edges, is idempotent per
#       task-id, and keeps the file cleanly formatted
#   (e) check enforces the headings and envelope, and hard-fails on a broken mission
#       while only soft-noting an unfilled placeholder
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MISSION="$ROOT/bin/fm-mission.sh"
TMP_ROOT=$(fm_test_tmproot fm-mission-tests)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

run_mission() {
  local home=$1; shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$MISSION" "$@"
}

# Plan a mission all the way to a clean, STUB-free state: criteria + two DAG tasks.
plan_mission() {
  local home=$1 id=$2
  printf '%s\n' "- all billing calls hit /v2 endpoints" "- zero calls to /v1 remain" \
    | run_mission "$home" set-criteria "$id" >/dev/null
  run_mission "$home" add-task "$id" scaffold-a1 >/dev/null
  run_mission "$home" add-task "$id" migrate-b2 --blocked-by scaffold-a1 >/dev/null
}

# (a) ------------------------------------------------------------------------
test_new_mints_id_and_scaffolds_sections() {
  local home out id
  home=$(make_home new)
  out=$(FM_MISSION_SUFFIX=k3 run_mission "$home" new "migrate billing to v2" --repo acme)
  id=$(printf '%s\n' "$out" | head -1)
  [ "$id" = "migrate-billing-to-v2-k3" ] || fail "new: minted id from goal+suffix, got '$id'"

  out=$(run_mission "$home" show "$id")
  assert_contains "$out" '## Goal' "new: goal heading"
  assert_contains "$out" 'migrate billing to v2' "new: records the goal verbatim"
  assert_contains "$out" '## Acceptance criteria' "new: acceptance-criteria heading"
  assert_contains "$out" '## Task DAG' "new: task DAG heading"
  assert_contains "$out" '## Autonomy envelope' "new: envelope heading"
  assert_contains "$out" '## Completion rollup' "new: rollup heading"
  assert_contains "$out" 'project: acme' "new: records the resolved project"
  assert_contains "$out" 'max-tasks: 15' "new: conservative default max-tasks"
  assert_contains "$out" 'max-spend-usd: 50' "new: conservative default max-spend"
  assert_contains "$out" 'max-wallclock-hours: 12' "new: conservative default wall-clock"
  pass "new mints an id and scaffolds the six required sections"
}

test_new_refuses_overwrite() {
  local home rc=0
  home=$(make_home new_overwrite)
  FM_MISSION_SUFFIX=k3 run_mission "$home" new "a goal" --id fixed-id >/dev/null
  run_mission "$home" new "another goal" --id fixed-id >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "new: must refuse to overwrite an existing mission id"
  pass "new refuses to overwrite an existing mission"
}

# (b) ------------------------------------------------------------------------
test_new_validates_and_overrides_envelope() {
  local home out rc
  home=$(make_home envelope)
  # Override at new.
  FM_MISSION_SUFFIX=z9 run_mission "$home" new "big mission" --max-tasks 40 --max-hours 48 >/dev/null
  out=$(run_mission "$home" show big-mission-z9)
  assert_contains "$out" 'max-tasks: 40' "new: honors --max-tasks override"
  assert_contains "$out" 'max-wallclock-hours: 48' "new: honors --max-hours override"

  # Reject non-positive / non-integer up front.
  rc=0; run_mission "$home" new "bad" --max-tasks 0 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "new: a zero envelope value must be rejected"
  rc=0; run_mission "$home" new "bad" --max-spend abc >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "new: a non-integer envelope value must be rejected"
  pass "new validates the envelope and honors per-mission overrides"
}

# (c) ------------------------------------------------------------------------
test_set_criteria_replaces_body_and_drops_placeholder() {
  local home out
  home=$(make_home criteria)
  FM_MISSION_SUFFIX=k3 run_mission "$home" new "a goal" --id crit-id >/dev/null
  printf '%s\n' "- criterion one is testable" "- criterion two is testable" \
    | run_mission "$home" set-criteria crit-id >/dev/null

  out=$(run_mission "$home" show crit-id)
  assert_contains "$out" 'criterion one is testable' "set-criteria: injects the criteria body"
  assert_not_contains "$out" 'Drafted by the planning pass' "set-criteria: drops the scaffold placeholder"
  # It must only touch its own section, leaving the goal and envelope intact.
  assert_contains "$out" '## Autonomy envelope' "set-criteria: leaves later sections intact"
  assert_contains "$out" 'max-tasks: 15' "set-criteria: does not disturb the envelope"
  pass "set-criteria replaces the criteria body and drops the placeholder"
}

test_set_criteria_requires_existing_mission() {
  local home rc=0
  home=$(make_home criteria_absent)
  printf '%s\n' "- x" | run_mission "$home" set-criteria nope >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "set-criteria must refuse a mission that does not exist"
  pass "set-criteria refuses a mission with no file"
}

# (d) ------------------------------------------------------------------------
test_add_task_records_edges_and_is_idempotent() {
  local home out count
  home=$(make_home dag)
  FM_MISSION_SUFFIX=k3 run_mission "$home" new "a goal" --id dag-id >/dev/null
  run_mission "$home" add-task dag-id scaffold-a1 >/dev/null
  run_mission "$home" add-task dag-id migrate-b2 --blocked-by scaffold-a1 >/dev/null
  run_mission "$home" add-task dag-id remove-c3 --blocked-by migrate-b2 --blocked-by scaffold-a1 >/dev/null

  out=$(run_mission "$home" show dag-id)
  assert_contains "$out" '- scaffold-a1' "add-task: records a root task"
  assert_contains "$out" '- migrate-b2 [blocked-by: scaffold-a1]' "add-task: records a single edge"
  assert_contains "$out" '- remove-c3 [blocked-by: migrate-b2, scaffold-a1]' "add-task: records multiple edges"
  assert_not_contains "$out" "membership roster" "add-task: drops the scaffold placeholder"

  # Re-adding the same task-id rewrites that one line, not a duplicate.
  run_mission "$home" add-task dag-id migrate-b2 --blocked-by scaffold-a1 >/dev/null
  count=$(run_mission "$home" show dag-id | grep -c -- '- migrate-b2')
  [ "$count" -eq 1 ] || fail "add-task: re-adding a task-id must not duplicate it (got $count)"

  # list counts the DAG members.
  assert_contains "$(run_mission "$home" list)" 'dag-id	3 tasks' "list: counts the DAG members"
  pass "add-task records edges, is idempotent per task-id, and list counts members"
}

# (d2) tasks + set-rollup: the boundary-respecting dispatcher surface ----------
test_tasks_prints_roster_ids_only() {
  local home out
  home=$(make_home roster)
  FM_MISSION_SUFFIX=k3 run_mission "$home" new "a goal" --id ros-id >/dev/null
  # A fresh mission's roster is empty (only the scaffold placeholder).
  [ -z "$(run_mission "$home" tasks ros-id)" ] || fail "tasks: an unplanned roster must be empty"

  run_mission "$home" add-task ros-id root-a1 >/dev/null
  run_mission "$home" add-task ros-id dep-b2 --blocked-by root-a1 >/dev/null
  out=$(run_mission "$home" tasks ros-id)
  # One id per line, first token only - never the blocked-by edge ids.
  [ "$out" = "root-a1
dep-b2" ] || fail "tasks: must print member ids one per line, got: $out"
  pass "tasks prints the DAG roster ids, one per line, edges excluded"
}

test_set_rollup_replaces_last_section() {
  local home out
  home=$(make_home rollup)
  FM_MISSION_SUFFIX=k3 run_mission "$home" new "a goal" --id rol-id >/dev/null
  printf '2 of 3 tasks landed; 1 in flight.' | run_mission "$home" set-rollup rol-id >/dev/null
  out=$(run_mission "$home" show rol-id)
  assert_contains "$out" '2 of 3 tasks landed; 1 in flight.' "set-rollup: writes the live rollup"
  assert_not_contains "$out" 'Not yet tracked' "set-rollup: drops the scaffold sentinel"
  # It must only touch the last section, leaving the envelope intact above it.
  assert_contains "$out" 'max-tasks: 15' "set-rollup: leaves the envelope intact"
  pass "set-rollup replaces the Completion rollup section"
}

# (e) ------------------------------------------------------------------------
test_check_soft_notes_stub_then_passes_clean() {
  local home out rc
  home=$(make_home check_clean)
  FM_MISSION_SUFFIX=k3 run_mission "$home" new "a goal" --id chk-id >/dev/null

  # A freshly scaffolded mission is a stub (unfilled criteria + DAG), but a stub is
  # a soft note, not a hard failure: the mission just is not fully planned yet.
  rc=0; out=$(run_mission "$home" check chk-id) || rc=$?
  [ "$rc" -eq 0 ] || fail "check: an unplanned stub must not hard-fail"
  assert_contains "$out" 'MISSION_STUB' "check: soft-notes the unfilled placeholders"

  # Once planned, check is clean and silent.
  plan_mission "$home" chk-id
  rc=0; out=$(run_mission "$home" check chk-id) || rc=$?
  [ "$rc" -eq 0 ] || fail "check: a fully-planned mission must pass"
  assert_not_contains "$out" 'MISSION_STUB' "check: no stub note once planned"
  assert_not_contains "$out" 'MISSION_INVALID' "check: no invalid note once planned"
  pass "check soft-notes a stub and passes clean once the mission is planned"
}

test_check_hard_fails_broken_mission() {
  local home out rc
  home=$(make_home check_broken)
  mkdir -p "$home/data/missions"
  # Missing a required heading AND a broken envelope value: both hard failures.
  cat > "$home/data/missions/broke-id.md" <<'EOF'
# broke-id - Mission

## Goal
do a thing

## Acceptance criteria
- something

## Task DAG
- only-task

## Autonomy envelope
max-tasks: zero
max-spend-usd: 50

## Completion rollup
Not yet tracked.
EOF
  rc=0; out=$(run_mission "$home" check broke-id) || rc=$?
  [ "$rc" -ne 0 ] || fail "check: a broken mission must hard-fail"
  assert_contains "$out" 'MISSION_INVALID' "check: reports the invalidity"
  assert_contains "$out" 'max-tasks' "check: names the bad envelope value"
  assert_contains "$out" 'max-wallclock-hours' "check: names the missing envelope key"
  pass "check hard-fails a mission with a missing heading or bad envelope"
}

test_check_reports_missing_without_failing() {
  local home out rc
  home=$(make_home check_missing)
  rc=0; out=$(run_mission "$home" check ghost) || rc=$?
  [ "$rc" -eq 0 ] || fail "check: a merely-absent mission must not fail"
  assert_contains "$out" 'MISSION_MISSING: ghost' "check: reports the absent mission"
  pass "check reports a missing mission without failing"
}

# Mission files live under data/, which is gitignored: personal, never committed.
test_mission_lives_under_data() {
  local home path
  home=$(make_home under_data)
  path=$(run_mission "$home" path some-id)
  case "$path" in
    "$home/data/missions/some-id.md") : ;;
    *) fail "path: mission must resolve under data/missions, got '$path'" ;;
  esac
  pass "missions live under the gitignored data/ home"
}

test_new_mints_id_and_scaffolds_sections
test_new_refuses_overwrite
test_new_validates_and_overrides_envelope
test_set_criteria_replaces_body_and_drops_placeholder
test_set_criteria_requires_existing_mission
test_add_task_records_edges_and_is_idempotent
test_tasks_prints_roster_ids_only
test_set_rollup_replaces_last_section
test_check_soft_notes_stub_then_passes_clean
test_check_hard_fails_broken_mission
test_check_reports_missing_without_failing
test_mission_lives_under_data
