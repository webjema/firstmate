#!/usr/bin/env bash
# Behavior tests for the contract that a blocking review verdict is marked on an
# open PR, not only in firstmate's chat with the user.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_agents_review_step_marks_the_pr() {
  local agents="$ROOT/AGENTS.md"

  assert_grep 'gh pr ready --undo' "$agents" "AGENTS.md review flow does not block the merge button on a firstmate-authored PR"
  assert_grep 'do-not-merge' "$agents" "AGENTS.md review flow does not give bot PRs the label path"
  assert_grep 'Never draft a bot' "$agents" "AGENTS.md review flow does not forbid drafting a bot's PR"
  assert_grep 'docs/pr-block-signal.md' "$agents" "AGENTS.md review flow does not point at the mechanics doc"
  pass "AGENTS.md review flow marks a merge-stopping verdict on the PR itself"
}

test_block_signal_doc_owns_the_mechanics() {
  local doc="$ROOT/docs/pr-block-signal.md"

  assert_present "$doc" "docs/pr-block-signal.md is missing"
  assert_grep 'gh pr ready <pr-url>' "$doc" "doc does not say how to clear a draft mark"
  assert_grep 'gh label create do-not-merge' "$doc" "doc does not say how to create the blocking label"
  assert_grep 'non-zero exit' "$doc" "doc does not key the fallback on --undo failing loudly"
  assert_grep 'draft guard' "$doc" "doc does not record whether drafting suppresses PR CI"
  pass "docs/pr-block-signal.md owns the commands, the label setup, and the CI evidence"
}

test_project_ci_has_no_draft_guard() {
  local wf="$ROOT/.github/workflows/ci.yml"

  # The draft path only works because drafting does not stop this repo's PR CI.
  # A `types:` filter or a draft conditional added to ci.yml would take the fix
  # loop's gate away and invalidate the instruction in AGENTS.md.
  assert_no_grep 'pull_request.draft' "$wf" "ci.yml gained a draft conditional - drafting a PR would now suppress its CI"
  assert_no_grep 'ready_for_review' "$wf" "ci.yml gained a ready_for_review types filter - draft pushes would no longer run CI"
  assert_grep 'pull_request:' "$wf" "ci.yml no longer runs on pull_request at all"
  pass "PR CI still runs on draft PRs, so the fix loop keeps its gate"
}

test_agents_review_step_marks_the_pr
test_block_signal_doc_owns_the_mechanics
test_project_ci_has_no_draft_guard
