#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
#
# The direction contract is the other load-bearing thing here: every ship and
# scout brief must carry the project's direction and the conflict-escalation
# rule, because that is the ONLY mechanism that makes a small bug fix get judged
# against the project's architecture and quality posture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in either DOD heredoc body (PR/local-only)
# breaks `bash -n` on the whole file.
test_script_parses() {
  bash -n "$ROOT/bin/fm-brief.sh" 2>&1 || fail "bin/fm-brief.sh fails bash -n (heredoc/quote regression)"
  pass "fm-brief.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry fails closed to PR mode.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- pr-proj [PR] - fixture for PR mode (added 2026-07-13)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-13)
- legacy-proj [no-mistakes] - fixture for the legacy token that must map to PR (added 2026-07-01)
EOF
}

write_direction() {
  local home=$1 project=$2
  mkdir -p "$home/data/directions"
  cat > "$home/data/directions/$project.md" <<'EOF'
# fixture - Direction

## Business vision
Sell widgets to procurement teams.

## Architecture direction
Every write goes through a command handler; no lambda touches the store directly.

## Infrastructure direction
CDK only. Nothing is deployed by hand.

## Quality direction
Root cause, never symptom.

## Standing decisions
- 2026-07-13 Alpha may lag prod by one release.
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id proj brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-pr-a1:pr-proj" "brief-default-a2:no-registry-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: PR and local-only briefs generate cleanly"
}

# A project registered with the retired no-mistakes token must still ship: the
# token maps to PR, so an un-migrated registry line never strands a project.
test_legacy_mode_token_maps_to_pr() {
  local home brief out
  home="$TMP_ROOT/legacy-home"
  write_registry "$home"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-legacy-b1 legacy-proj 2>&1)
  assert_contains "$out" "mode=PR" "legacy [no-mistakes] token did not resolve to PR"
  brief="$home/data/brief-legacy-b1/brief.md"
  assert_grep "ships by **pull request**" "$brief" "legacy-token brief did not get the PR definition of done"
  assert_no_grep "no-mistakes" "$brief" "legacy-token brief still references the retired pipeline"
  pass "fm-brief.sh: the legacy no-mistakes registry token maps to PR mode"
}

# The PR definition of done is the whole replacement for the retired pipeline:
# the crew self-reviews, verifies, respects the hooks, and stops at the PR.
test_pr_dod_carries_the_review_contract() {
  local home brief
  home="$TMP_ROOT/pr-dod-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-dod-b2 pr-proj >/dev/null 2>&1
  brief="$home/data/brief-dod-b2/brief.md"

  assert_grep '/code-review' "$brief" "PR DOD lost the self-review step"
  assert_grep '/verify' "$brief" "PR DOD lost the end-to-end verify step"
  assert_grep "Do NOT merge the PR" "$brief" "PR DOD lost the never-merge rule"
  assert_grep "never work around the gate" "$brief" "PR DOD lost the do-not-bypass-hooks rule"
  assert_grep "# Quality floor" "$brief" "ship brief lost the quality-floor section"
  assert_grep "fm-hooks-install.sh" "$brief" "quality floor does not point at the hook installer"
  # A judgment call is the user's, not the crew's, even mid-review.
  assert_grep "is NOT yours to decide" "$brief" "PR DOD lost the escalate-judgment-calls rule"
  pass "fm-brief.sh: the PR definition of done carries the full review contract"
}

# The direction contract. This is what makes even a one-line bug fix get judged
# against the project's architecture and quality posture.
test_direction_is_injected_into_ship_and_scout() {
  local home id brief kind
  home="$TMP_ROOT/direction-home"
  write_registry "$home"
  write_direction "$home" pr-proj

  for kind in ship scout; do
    id="brief-direction-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" pr-proj --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" pr-proj >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind: brief was not scaffolded"
    assert_grep "# Direction" "$brief" "$kind brief lost the Direction section"
    assert_grep "no lambda touches the store directly" "$brief" "$kind brief did not inject the architecture direction"
    assert_grep "Alpha may lag prod" "$brief" "$kind brief did not inject the standing-decisions ledger"
    assert_grep "direction conflict" "$brief" "$kind brief lost the conflict-escalation contract"
  done

  # The ship brief additionally owes a direction self-check before it reports done.
  assert_grep "Direction check" "$home/data/brief-direction-ship/brief.md" \
    "ship DOD lost the direction self-check step"
  # And the direction must never be copied into the project's own memory file.
  assert_grep "never copy it into the project" "$home/data/brief-direction-ship/brief.md" \
    "ship brief lost the do-not-copy-direction-into-the-project rule"
  pass "fm-brief.sh: direction is injected into ship and scout briefs with its contract"
}

# A project with no direction yet must still produce a usable brief that says so
# explicitly - a crewmate must never confuse "no direction exists" with a broken
# scaffold, and must know to escalate rather than guess at product intent.
test_absent_direction_is_explicit_not_silent() {
  local home brief
  home="$TMP_ROOT/no-direction-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-nodir-c1 pr-proj >/dev/null 2>&1
  brief="$home/data/brief-nodir-c1/brief.md"

  assert_grep "# Direction" "$brief" "brief lost the Direction heading when no direction exists"
  assert_grep "No direction is on file" "$brief" "brief did not say the direction is absent"
  assert_grep "needs-decision" "$brief" "brief did not tell the crew to escalate instead of guessing"
  pass "fm-brief.sh: an absent direction is stated explicitly, never silently empty"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

# Every ship and scout brief must instruct the crewmate to read the target
# project's CLAUDE.md and AGENTS.md before starting work, so it absorbs the
# project's rules and architecture first.
test_read_project_docs_instruction() {
  local home id brief
  home="$TMP_ROOT/read-docs-home"
  mkdir -p "$home/data"

  for kind in ship scout; do
    id="brief-read-docs-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind: brief was not scaffolded"
    # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
    assert_grep 'the project'\''s `CLAUDE.md` and `AGENTS.md`' "$brief" \
      "$kind brief missing the read-project-docs instruction"
    assert_grep "follow any imports or parent-guide pointers they reference" "$brief" \
      "$kind brief missing the imports/parent-guide follow instruction"
  done
  pass "fm-brief.sh: ship and scout briefs instruct reading project CLAUDE.md/AGENTS.md"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

# A secondmate supervises projects, so its charter must point it at the direction
# store; otherwise a secondmate would brief its own crewmates without direction.
test_secondmate_charter_points_at_direction() {
  local home brief
  home="$TMP_ROOT/secondmate-direction-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_SECONDMATE_CHARTER='triage' \
    "$ROOT/bin/fm-brief.sh" sdir --secondmate alpha >/dev/null 2>&1
  brief="$home/data/sdir/brief.md"
  assert_grep "data/directions/<project>.md" "$brief" \
    "secondmate charter does not point at the direction store"
  assert_grep "judge their work against it" "$brief" \
    "secondmate charter does not require judging crew work against the direction"
  pass "fm-brief.sh: a secondmate charter points at the direction store"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_legacy_mode_token_maps_to_pr
test_pr_dod_carries_the_review_contract
test_direction_is_injected_into_ship_and_scout
test_absent_direction_is_explicit_not_silent
test_ship_project_memory_wording
test_read_project_docs_instruction
test_secondmate_no_projects_charter
test_secondmate_charter_points_at_direction
test_pause_verb_override_renders_all_brief_scaffolds
