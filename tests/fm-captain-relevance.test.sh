#!/usr/bin/env bash
# tests/fm-captain-relevance.test.sh - captain-relevance is anchored to the verb.
#
# status_is_captain_relevant used to grep the WHOLE status line for
# done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged.
# The note after the verb is free prose written by a crewmate, so
#   working: rebased onto merged main
# escalated as captain-relevant - the bare word "merged" was enough - and burned a
# full firstmate turn on a routine progress note. The verb is the crew's claim;
# everything after the colon is commentary.
#
# The whole-line regex survives ONLY as the explicit FM_CAPTAIN_RE escape hatch, so
# a home that deliberately wants its own vocabulary still has one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

test_prose_never_escalates() {
  # The regression, verbatim.
  status_is_captain_relevant "working: rebased onto merged main" \
    && fail "a working: note mentioning 'merged' escalated as captain-relevant"

  # Every other way the old substring scan could fire on ordinary prose.
  status_is_captain_relevant "working: waiting for checks green before pushing" \
    && fail "a working: note mentioning 'checks green' escalated"
  status_is_captain_relevant "working: the PR ready check is still running" \
    && fail "a working: note mentioning 'PR ready' escalated"
  status_is_captain_relevant "working: got the repro ready in branch fm/x" \
    && fail "a working: note mentioning 'ready in branch' escalated"
  status_is_captain_relevant "working: this is not done: not even close" \
    && fail "a working: note quoting a verb later in the prose escalated"
  pass "prose in a working: note never escalates, whatever words it contains"
}

test_verbs_still_escalate() {
  status_is_captain_relevant "done: PR https://example.invalid/pull/1" \
    || fail "done: no longer escalates"
  status_is_captain_relevant "done: ready in branch fm/x" \
    || fail "done: with a local-only note no longer escalates"
  status_is_captain_relevant "needs-decision: A or B" || fail "needs-decision: no longer escalates"
  status_is_captain_relevant "needs-decision [key=api]: A or B" \
    || fail "a keyed needs-decision no longer escalates"
  status_is_captain_relevant "blocked: no credentials" || fail "blocked: no longer escalates"
  status_is_captain_relevant "failed: the suite is red" || fail "failed: no longer escalates"

  # paused: is deliberately NOT captain-relevant (it means "stop nagging this idle
  # pane"), and an empty line is nothing at all.
  status_is_captain_relevant "paused: waiting on the upstream release" \
    && fail "paused: escalated"
  status_is_captain_relevant "" && fail "an empty line escalated"
  pass "the four captain verbs still escalate, and paused: still does not"
}

test_override_is_the_one_non_verb_path() {
  # An explicit FM_CAPTAIN_RE is a home asking for a whole-line vocabulary, and gets
  # it - this is the ONE surviving non-verb escalation path, and it is opt-in.
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" \
    || fail "FM_CAPTAIN_RE override not honored"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "done: x" \
    && fail "FM_CAPTAIN_RE override did not replace the default verb set"
  FM_CAPTAIN_RE='merged' status_is_captain_relevant "working: rebased onto merged main" \
    || fail "an explicit whole-line override did not match the whole line"
  pass "FM_CAPTAIN_RE remains the explicit, opt-in whole-line escape hatch"
}

test_prose_never_escalates
test_verbs_still_escalate
test_override_is_the_one_non_verb_path
