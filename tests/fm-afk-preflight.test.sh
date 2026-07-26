#!/usr/bin/env bash
# tests/fm-afk-preflight.test.sh - the away-mode entry preflight
# (bin/fm-afk-preflight-lib.sh): away mode must PROVE it can reach the supervisor
# pane while the user is still at the keyboard, and fail closed and loudly when it
# cannot.
#
# The incident this exists for (afk-wake-fix-r4, 2026-07-26): away mode started
# cleanly against a pane whose composer the classifier misread, the user walked
# away, and every escalation deferred for 26,211s. Nothing was lost and nothing
# arrived. The preflight closes that window - the same misread that wedged
# delivery now refuses ENTRY, in front of the user, with the pane named.
#
# The fake tmux surface (make_supercase) is the wake-suite one, so the pane these
# tests classify is classified through exactly the reader and classifier the
# daemon's injector uses.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# shellcheck source=bin/fm-afk-preflight-lib.sh
. "$ROOT/bin/fm-afk-preflight-lib.sh"

AFK_START="$ROOT/bin/fm-afk-start.sh"
TMP_ROOT=$(fm_test_tmproot fm-afk-preflight-tests)

# run_preflight: drive fm_afk_preflight against a fake pane whose cursor row is
# the given raw bytes. Prints combined output; returns the preflight's status.
run_preflight() {  # <case-name> <cursor-row-bytes> [extra env assignments...]
  local name=$1 row=$2; shift 2
  local dir fakebin capture
  dir=$(make_supercase "$name")
  fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  printf '%b\n' "$row" > "$capture"
  # shellcheck disable=SC2016  # $0 is expanded by the inner shell, not this one
  env PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURSOR_Y=0 FM_SUPERVISOR_TARGET=fake:0 FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_PREFLIGHT_ATTEMPTS=2 FM_AFK_PREFLIGHT_SLEEP=0 "$@" \
    bash -c '. "$0"; fm_afk_preflight' "$ROOT/bin/fm-afk-preflight-lib.sh" 2>&1
}

test_preflight_passes_on_an_empty_composer() {
  local out status
  # A bordered, idle composer with a dim placeholder inside it - the ordinary
  # "firstmate is sitting there waiting" shape.
  out=$(run_preflight preflight-empty '\342\224\202 > \033[2mTry "fix the build"\033[0m \342\224\202'); status=$?
  [ "$status" -eq 0 ] || fail "preflight refused a genuinely idle composer: $out"
  assert_contains "$out" "preflight ok" "preflight did not report the wake path verified"
  pass "preflight passes when the supervisor composer reads empty"
}

test_preflight_passes_on_the_real_incident_composer() {
  local out status
  # The exact bytes captured from the wedged pane: SGR 37, U+276F, U+00A0, SGR 39.
  # Away mode may enter here - and MUST, because this pane was perfectly healthy;
  # only the classifier was wrong. The refusal cases below prove the gate still
  # bites when the pane genuinely cannot be reached.
  out=$(run_preflight preflight-incident '\033[37m\342\235\257\302\240\033[39m'); status=$?
  [ "$status" -eq 0 ] || fail "preflight refused the real (healthy) incident composer: $out"
  assert_contains "$out" "preflight ok" "preflight did not verify the wake path on the incident row"
  pass "preflight passes on the real captured incident composer row"
}

test_preflight_refuses_a_pending_composer_with_a_capture_command() {
  local out status
  out=$(run_preflight preflight-pending 'half a message the user is typing'); status=$?
  [ "$status" -ne 0 ] || fail "preflight entered away mode over unsubmitted text"
  assert_contains "$out" "REFUSING to enter away mode" "refusal was not stated plainly"
  assert_contains "$out" "composer verdict: pending" "refusal did not name the verdict"
  assert_contains "$out" "fake:0" "refusal did not name the pane it probed"
  # The actionable half: a user whose line LOOKS empty needs the bytes.
  assert_contains "$out" "capture-pane" "refusal gave no way to diagnose a misread"
  pass "preflight refuses a pending composer and says how to diagnose a misread"
}

test_preflight_refuses_an_unreadable_composer() {
  local out status
  # A bare shell prompt outside a border: the agent has exited, so injecting here
  # would type an escalation into a SHELL. The classifier calls this unknown.
  out=$(run_preflight preflight-unknown '$ '); status=$?
  [ "$status" -ne 0 ] || fail "preflight entered away mode against an unreadable pane"
  assert_contains "$out" "composer verdict: unknown" "refusal did not name the unknown verdict"
  assert_contains "$out" "running firstmate" "unknown refusal gave no next step"
  pass "preflight refuses an unreadable composer (a dead shell prompt)"
}

test_preflight_refuses_a_missing_pane() {
  local dir out status
  dir=$(make_supercase preflight-missing)
  # shellcheck disable=SC2016  # $0 is expanded by the inner shell, not this one
  out=$(PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=0 \
    FM_SUPERVISOR_TARGET=gone:0 FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_PREFLIGHT_ATTEMPTS=2 FM_AFK_PREFLIGHT_SLEEP=0 \
    bash -c '. "$0"; fm_afk_preflight' "$ROOT/bin/fm-afk-preflight-lib.sh" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "preflight entered away mode with no supervisor pane at all"
  assert_contains "$out" "composer verdict: missing" "refusal did not name the missing pane"
  assert_contains "$out" "FM_SUPERVISOR_TARGET" "missing-pane refusal gave no next step"
  pass "preflight refuses when the supervisor pane does not exist"
}

test_preflight_override_is_loud() {
  local out status
  out=$(run_preflight preflight-override 'half a message the user is typing' FM_AFK_PREFLIGHT=0)
  status=$?
  [ "$status" -eq 0 ] || fail "FM_AFK_PREFLIGHT=0 did not skip the check"
  assert_contains "$out" "UNVERIFIED" "the override skipped silently instead of stating the reduced guarantee"
  pass "FM_AFK_PREFLIGHT=0 skips the check but states the reduced guarantee"
}

# The gate is only worth having if it fires BEFORE away mode writes anything: a
# half-entered away mode is exactly the state the incident left the user in.
test_afk_start_refuses_before_writing_the_afk_flag() {
  local dir state out status
  dir=$(make_supercase preflight-start-gate)
  state="$dir/start-state"; mkdir -p "$state"
  printf 'half a message the user is typing\n' > "$dir/pane.txt"
  out=$(PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURSOR_Y=0 FM_SUPERVISOR_TARGET=fake:0 FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_PREFLIGHT_ATTEMPTS=1 FM_AFK_PREFLIGHT_SLEEP=0 \
    FM_STATE_OVERRIDE="$state" "$AFK_START" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "fm-afk-start.sh entered away mode despite a failed preflight"
  assert_not_contains "$out" "starting supervise daemon" "fm-afk-start.sh started the daemon anyway"
  assert_absent "$state/.afk" "fm-afk-start.sh wrote the afk flag before proving the wake path"
  assert_absent "$state/.supervise-daemon.log" "fm-afk-start.sh started the daemon after a failed preflight"
  pass "fm-afk-start.sh refuses on a failed preflight, leaving no away-mode state behind"
}

test_preflight_passes_on_an_empty_composer
test_preflight_passes_on_the_real_incident_composer
test_preflight_refuses_a_pending_composer_with_a_capture_command
test_preflight_refuses_an_unreadable_composer
test_preflight_refuses_a_missing_pane
test_preflight_override_is_loud
test_afk_start_refuses_before_writing_the_afk_flag
