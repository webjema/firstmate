#!/usr/bin/env bash
# tests/fm-wake-queue.test.sh - wake-queue losslessness (the queue safety matrix):
# concurrent append/drain, signal catch-up while no watcher runs, stale/check
# enqueue-before-suppressor ordering, atomic double-drain, duplicate collapse,
# the drain-time watcher-liveness assertion, and the disk-guard kind's round trip.
# Nothing is lost and nothing is double-consumed. General watcher/lock liveness
# lives in fm-watcher-lock.test.sh; daemon classification/injection in
# fm-daemon.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-tests)


# The wake vocabulary was four hand-written copies, and the fourth kind added
# (disk-guard) reached exactly one of them. This is the check that keeps the fifth
# from repeating it: every kind must be accepted by BOTH call shapes and by the
# queue's own gate, and no consumer may re-spell the alternation.
test_wake_vocabulary_has_exactly_one_owner() {
  local kind copies
  # shellcheck source=bin/fm-wake-kind-lib.sh
  . "$ROOT/bin/fm-wake-kind-lib.sh"
  for kind in $FM_WAKE_KINDS; do
    # The bare shape (bin/fm-watch.sh's wake() echoes its reason verbatim, and the
    # kinds with no target are emitted with no colon at all) and the payload shape.
    fm_is_wake_reason "$kind" || fail "bare wake kind '$kind' is not recognised as a wake"
    fm_is_wake_reason "$kind: some payload" || fail "wake kind '$kind:' is not recognised as a wake"
    fm_wake_kind_valid "$kind" || fail "wake kind '$kind' is rejected by the durable queue's gate"
    printf '%s\n' "$kind" | grep -Eq "$FM_WAKE_LINE_RE" \
      || fail "wake kind '$kind' is missed by the file-scanning regex the arm and checkpoint use"
  done
  # A status line the watcher prints on a singleton collision must stay a non-wake:
  # the daemon idles it, and misreading it floods the escalation buffer.
  fm_is_wake_reason "watcher: already running" && fail "a watcher status line is classified as a wake"
  # Every consumer of the vocabulary must ask the owner rather than keep a copy.
  copies=$(grep -rlE '\(signal:|signal:\*\|' "$ROOT"/bin/*.sh || true)
  [ -z "$copies" ] || fail "the wake alternation is re-spelled outside its owner: $copies"
  for kind in fm-watch-arm.sh fm-watch-checkpoint.sh fm-supervise-daemon.sh; do
    grep -qE 'FM_WAKE_LINE_RE|fm_is_wake_reason' "$ROOT/bin/$kind" \
      || fail "bin/$kind does not use bin/fm-wake-kind-lib.sh's predicate"
  done
  pass "every wake kind is served by one owner, and no consumer keeps a second copy"
}

test_concurrent_append_and_drain() {
  local dir state out1 out2 all pids i pid count unique malformed
  dir=$(make_case concurrent)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    append_wake "$state" signal "status-$i" "signal: $state/status-$i.status" &
    pids="$pids $!"
    i=$((i + 1))
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pids="$pids $!"
  for pid in $pids; do
    wait "$pid" || fail "concurrent append/drain subprocess failed"
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" || fail "final drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 40 ] || fail "expected 40 drained records, got $count"
  malformed=$(awk -F '\t' 'NF != 5 { bad++ } END { print bad + 0 }' "$all")
  [ "$malformed" -eq 0 ] || fail "drained records had malformed fields"
  unique=$(awk -F '\t' '{ keys[$4] = 1 } END { for (k in keys) count++; print count + 0 }' "$all")
  [ "$unique" -eq 40 ] || fail "expected 40 unique keys, got $unique"
  pass "concurrent append plus drain preserves queue records"
}

test_signal_catchup_without_running_watcher() {
  local dir state fakebin out drain_out status_file
  dir=$(make_case signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  status_file="$state/task.status"
  # The durable-queue catch-up contract applies to ACTIONABLE wakes (the always-on
  # watcher can absorb no-verb working: notes when the crew is provably working).
  # Use a captain-relevant verb so the wake is surfaced and the catch-up path is
  # tested.
  printf 'blocked: first\n' > "$status_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for first signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print first signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after first signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "first signal was not queued"

  printf 'done: second\n' >> "$status_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for second signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "signal written with no watcher was not caught"
  pass "signal written while no watcher runs is caught on next run"
}

test_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stale"
  printf 'idle prompt' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stale.meta"
  # A stale pane sitting on a captain-relevant status is actionable when the crew
  # is not provably working, so give the window one and prime the .seen-* marker
  # to its current signature so the per-poll signal scan does not pre-empt the
  # stale wake with a signal wake.
  printf 'done: ready in branch fm/stale\n' > "$state/stale.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$state/stale.status"); else sig=$(stat -c '%s:%Y' "$state/stale.status"); fi
  printf '%s' "$sig" > "$state/.seen-stale_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for stale pane"
  grep -F "stale: $window | task=" "$out" >/dev/null || fail "watcher did not print stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not written"
  pass "stale wake is queued before suppressor state is advanced"
}

# Absorb-only-when-provably-working adds a new actionable wake: a non-terminal stale
# whose crew is NOT provably working is surfaced immediately. That new path must keep
# the queue-safety invariant - enqueue the stale wake BEFORE advancing the .stale-*
# suppressor - so a watcher killed between the two never swallows the surfaced finish.
test_not_working_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale-stopped)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (no captain-relevant verb); prime .seen-* so the per-poll
  # signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$state/stopped.status"); else sig=$(stat -c '%s:%Y' "$state/stopped.status"); fi
  printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # NOT provably working: no running pipeline, idle pane. (make_case installed the
  # fake fm-crew-state.sh the watcher reads via FM_CREW_STATE_BIN.)
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not surface a not-provably-working stale"
  grep -F "stale: $window | task=" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after the immediate stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced after the enqueue"
  unset FM_FAKE_CREW_STATE
  pass "a not-provably-working stale wake is queued before its suppressor is advanced"
}

test_check_output_is_queued() {
  local dir state fakebin out drain_out check_file
  dir=$(make_case check)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/1\n'
SH
  chmod +x "$check_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for check output"
  grep -F "check: $check_file: merged: https://example.test/pr/1" "$out" >/dev/null || fail "watcher did not print check wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after check wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/1' >/dev/null || fail "check wake was not queued"
  [ -e "$state/.last-check" ] || fail "check cadence marker was not written after queue append"
  pass "check output is queued before cadence suppression"
}

test_atomic_double_drain() {
  local dir state out1 out2 all count leftover
  dir=$(make_case double-drain)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  all="$dir/all.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  append_wake "$state" signal task "signal: $state/task.status" || fail "signal append failed"
  append_wake "$state" stale 's:fm-task' 'stale: s:fm-task' || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pid1=$!
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" &
  pid2=$!
  wait "$pid1" || fail "first drain failed"
  wait "$pid2" || fail "second drain failed"
  cat "$out1" "$out2" > "$all"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$all")
  [ "$count" -eq 3 ] || fail "two drains consumed records more than once or lost records; got $count"
  leftover=$(FM_STATE_OVERRIDE="$state" "$DRAIN" | awk 'NF { count++ } END { print count + 0 }')
  [ "$leftover" -eq 0 ] || fail "queue was not empty after double drain"
  pass "two atomic drains cannot consume the same records twice"
}

test_drain_dedupes_obvious_duplicates() {
  local dir state out count
  dir=$(make_case dedupe)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "first heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "first signal append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "second heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status $state/task.turn-ended" || fail "second signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "dedupe drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected 2 deduped records, got $count"
  grep "$(printf '\theartbeat\theartbeat\theartbeat')" "$out" >/dev/null || fail "heartbeat was not preserved"
  grep "$(printf '\tsignal\ttask.status\t')" "$out" | grep -F "$state/task.turn-ended" >/dev/null || fail "latest signal payload was not preserved"
  pass "drain collapses obvious duplicate heartbeat and signal records"
}

# The drain runs at the top of every wake-handling turn, so it also asserts
# watcher liveness via fm-guard.sh: a lapsed re-arm chain then surfaces even on a
# plain drain-and-handle turn that runs no other supervision script. It must warn
# when work is in flight with no live watcher, and stay silent right after a
# normal fire (a fresh beacon within grace), so it never false-alarms every wake.
test_drain_asserts_watcher_liveness() {
  local dir state err sleeper watch_path
  dir=$(make_case drain-liveness)
  state="$dir/state"
  err="$dir/drain.err"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || fail "drain failed while asserting liveness"
  grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "drain did not surface the watcher-down banner with work in flight and no live watcher"
  # A fresh beacon over NO live lock (an orphaned watcher) must STILL read as down:
  # ownership of the home lock, not beacon freshness, is the liveness truth.
  : > "$err"
  touch "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_GUARD_GRACE=300 "$DRAIN" >/dev/null 2> "$err" || fail "drain failed with a fresh beacon"
  grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "drain trusted a fresh beacon with no live lock as a live watcher"
  # A genuinely live, identity-matched watcher lock with a fresh beacon -> silence.
  : > "$err"
  sleep 60 &
  sleeper=$!
  watch_path="$(cd "$ROOT/bin" && pwd)/fm-watch.sh"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$sleeper" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$watch_path" > "$state/.watch.lock/watcher-path"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$sleeper" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" FM_HOME="$dir" FM_GUARD_GRACE=300 "$DRAIN" >/dev/null 2> "$err" || fail "drain failed with a live watcher lock"
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  if grep -F 'WATCHER DOWN' "$err" >/dev/null; then
    fail "drain false-alarmed with a live, identity-matched watcher lock and fresh beacon"
  fi
  pass "drain asserts watcher liveness: warns on a lapse, down for a fresh-beacon orphan, silent for a live lock"
}

# A disk-guard wake is a real wake kind: AGENTS.md section 7 has firstmate relay it
# to the captain verbatim, because only they may drop a crew's lease. Its evidence -
# which worktrees are held and what they would reclaim - exists ONLY in the queued
# payload; the watcher's stdout fast-path prints the bare word "disk-guard". So a
# disk-guard record the queue rejects is the whole warning lost the moment the arm
# is reaped, which is the exact failure the durable queue exists to prevent.
test_disk_guard_wake_is_queued() {
  local dir state fakebin fakeroot out drain_out
  dir=$(make_case disk-guard)
  state="$dir/state"
  fakebin="$dir/fakebin"
  fakeroot="$dir/fakeroot"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  # The watcher runs $FM_ROOT/bin/fm-disk-guard.sh, so a fake root is the whole mock.
  mkdir -p "$fakeroot/bin"
  cat > "$fakeroot/bin/fm-disk-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'tier: low - 12G reclaimable\n'
printf '2 worktrees are LEASED and were not touched: alpha-a1, beta-b2\n'
printf 'a lease is a crew claim; release them yourself with: treehouse destroy alpha-a1 --yes;\n'
SH
  chmod +x "$fakeroot/bin/fm-disk-guard.sh"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fakeroot" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_DISK_GUARD_INTERVAL=0 "$WATCH" > "$out" &
  wait_for_exit "$!" 60 || fail "watcher did not exit for the disk-guard holdback"
  ! grep -F 'wake-queue write FAILED' "$out" >/dev/null \
    || fail "the disk-guard wake was REJECTED by the queue: $(cat "$out")"
  grep -Fx 'disk-guard' "$out" >/dev/null || fail "watcher did not print the disk-guard wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after disk-guard wake failed"
  grep "$(printf '\tdisk-guard\tdisk-guard\t')" "$drain_out" >/dev/null \
    || fail "disk-guard wake was not queued; it survives only on stdout and dies with the arm"
  grep -F 'LEASED and were not touched' "$drain_out" >/dev/null \
    || fail "the drained disk-guard record lost the holdback payload the captain must be shown"
  grep -F 'treehouse destroy alpha-a1' "$drain_out" >/dev/null \
    || fail "the drained disk-guard record lost the release command AGENTS.md tells the captain to relay verbatim"
  pass "a disk-guard wake reaches the durable queue and drains with its payload intact"
}

# Repeat disk-guard records collapse on kind+key like every other non-heartbeat
# wake, so a queue left undrained across several holdback changes surfaces the
# newest report once instead of a pile of superseded ones.
test_disk_guard_records_dedupe_to_the_newest() {
  local dir state out count
  dir=$(make_case disk-guard-dedupe)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" disk-guard disk-guard 'disk-guard: 2 worktrees LEASED' \
    || fail "disk-guard append was rejected by fm_wake_append"
  append_wake "$state" disk-guard disk-guard 'disk-guard: 3 worktrees LEASED' \
    || fail "second disk-guard append was rejected by fm_wake_append"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "disk-guard dedupe drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 1 ] || fail "expected 1 deduped disk-guard record, got $count"
  grep -F '3 worktrees LEASED' "$out" >/dev/null || fail "the newest disk-guard payload was not preserved"
  pass "duplicate disk-guard records collapse to the newest"
}

test_wake_vocabulary_has_exactly_one_owner
test_concurrent_append_and_drain
test_signal_catchup_without_running_watcher
test_stale_enqueue_before_suppressor
test_not_working_stale_enqueue_before_suppressor
test_check_output_is_queued
test_atomic_double_drain
test_drain_dedupes_obvious_duplicates
test_drain_asserts_watcher_liveness
test_disk_guard_wake_is_queued
test_disk_guard_records_dedupe_to_the_newest
