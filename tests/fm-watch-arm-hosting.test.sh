#!/usr/bin/env bash
# tests/fm-watch-arm-hosting.test.sh - WHERE bin/fm-watch-arm.sh runs the watcher,
# and what that has to keep true.
#
# The harness reaps a background task by walking its task shell's ppid DESCENDANTS
# and signalling each one. `setsid` changes a process's session and group and NOT its
# ppid, so a setsid'd watcher stayed a descendant of its arm and died on every reap -
# with the arm's spare-a-confirmed-child fix working perfectly and irrelevant.
# docs/incidents/watcher-harness-reap.md holds the measurement. The watcher is now
# hosted in a tmux pane, where its parent is the tmux server.
#
# The contract these cases lock down:
#   1. A confirmed watcher survives a HARNESS-SHAPED reap of its arm - TERM to every
#      ppid-descendant, then to the arm. This is the case setsid could not answer and
#      the only one that tells the two hostings apart.
#   2. It still survives a process-GROUP kill (the F2 guarantee, not regressed).
#   3. Exactly one watcher per home: a second arm stands by instead of starting one,
#      which needs the OWNER CLAIM, because a hosted watcher's parent is the tmux
#      server and the old ppid proxy would read every watcher as an orphan to adopt.
#   4. bin/fm-supervision-live.sh stays truthful in all four states: live, orphaned
#      (arm gone, watcher up), killed, and ended normally.
#   5. A wake raised after the arm is gone still reaches the durable queue and drains
#      intact - the whole reason a surviving watcher loses nothing.
#   6. Two homes on one host do not collide: each gets its own watcher session, and
#      neither uses the crew's fm-<id> window namespace.
#
# ISOLATION. This suite talks to a REAL tmux server, so it runs one of its own on a
# private socket via a PATH shim and kills it on the way out; nothing here can see the
# host's sessions. Each case is its own FM_HOME with its own state and its own bin.
# It backgrounds real arms and bounded-waits on them, so it belongs in bin/fm-test.sh's
# serial tail alongside tests/fm-watch-arm-supervision.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-arm-hosting)

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-arm-hosting-$$"

# A watcher now outlives the arm that started it BY DESIGN, and it is not a child of
# this runner at all - it is a tmux pane's child - so nothing reaps it when a case
# ends. Match on the command line naming THIS run's temp root: it covers arms,
# launchers and watchers alike, and a recycled pid can never be mistaken for one of
# ours. The runner's own command line does not name the temp root, so it cannot reap
# itself, and no live home's watcher can match either.
reap_case_processes() {
  local pid args
  while read -r pid args; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "$$" ] && continue
    case "$args" in
      *"$TMP_ROOT"*) kill -9 "$pid" 2>/dev/null || true ;;
    esac
  done < <(ps -eo pid=,args= 2>/dev/null || true)
}
cleanup_all() {
  local rc=$?
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  reap_case_processes
  assert_no_host_watcher_sessions || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_all EXIT

# Every bare `tmux` the arm runs goes to OUR server. TMUX is unset so a suite running
# inside tmux cannot have its own session treated as the ambient one.
SHIM_DIR="$TMP_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH
unset TMUX

# `remain-on-exit on` GLOBALLY, because the box firstmate runs on sets exactly that so a
# crashed crew pane stays readable - and under it a pane whose command has exited does
# not close, it sits there dead. A private server left on the default would let every
# case pass while the real one accumulated a dead window per relaunch. start-server
# rather than a holder session: a session here would show up in the namespace assertions.
"$REAL_TMUX" -L "$SOCKET" start-server 2>/dev/null || true
"$REAL_TMUX" -L "$SOCKET" set-option -g remain-on-exit on 2>/dev/null || true

# Hosting is what this file is about, so it leaves the choice on `auto` - the arm picks
# tmux because the shim answers - rather than pinning it.
ARM_HOST=auto
# shellcheck source=tests/arm-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/arm-helpers.sh"

ppid_of() {  # <pid>
  ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '
}

# The arm's OWN pid, read from the marker it writes, because a `setsid`'d arm's pid is
# not the `$!` of the shell that started it.
arm_pid_from_marker() {  # <dir>
  sed -n 's/^pid=//p' "$1/state/.watch.arming" 2>/dev/null | head -1
}

wait_for_pid_gone() {  # <pid> [limit]
  local pid=$1 limit=${2:-100} i=0
  while [ "$i" -lt "$limit" ]; do
    is_live_non_zombie "$pid" || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_marker_pid() {  # <dir> [limit]
  local dir=$1 limit=${2:-100} i=0 pid
  while [ "$i" -lt "$limit" ]; do
    pid=$(arm_pid_from_marker "$dir")
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) printf '%s' "$pid"; return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Every ppid-descendant of a pid, from one ps snapshot, parents before children.
descendants_of() {  # <pid>
  local frontier=$1 next pid ppid snapshot
  snapshot=$(ps -eo pid=,ppid= 2>/dev/null || true)
  while [ -n "$frontier" ]; do
    next=
    while read -r pid ppid; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      case " $frontier " in
        *" $ppid "*) printf '%s\n' "$pid"; next="$next $pid" ;;
      esac
    done <<< "$snapshot"
    frontier=$next
  done
}

# Reap the way the harness reaps its own background task, which is the shape that was
# actually killing watchers: signal the descendants, then the task shell. It walks DOWN
# from one arm pid, so it can never reach anything but that arm's own tree.
harness_reap() {  # <arm-pid>
  local p
  for p in $(descendants_of "$1"); do
    kill -TERM "$p" 2>/dev/null || true
  done
  kill -TERM "$1" 2>/dev/null || true
}

supervision_live() {  # <dir>
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    "$1/bin/fm-supervision-live.sh" 2>&1
}

# Scoped to ONE home, deliberately. A watcher outlives its arm by design, so its
# window is still there when the next case runs, and a count over the whole server
# grows with every case that came before it. Panes are matched on the launcher path,
# which names the home's own state dir.
watcher_panes_of() {  # <dir> -> the session names hosting that home's watcher
  tmux list-panes -a -F '#{session_name}	#{pane_start_command}' 2>/dev/null \
    | grep -F "$1/state/" | cut -f1
}

watcher_windows_of() {  # <dir>
  watcher_panes_of "$1" | grep -c . || true
}

test_hosted_watcher_survives_a_harness_reap() {
  local dir armout armpid wpid
  dir=$(make_arm_case reap)
  armout="$dir/arm.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' \
    || fail "arm never confirmed a hosted watcher: $(cat "$armout")"
  wpid=$(confirmed_watcher_pid "$armout")
  [ -n "$wpid" ] || fail "no confirmed watcher pid in: $(cat "$armout")"

  # The whole mechanism in one assertion: a watcher whose parent is its arm is a
  # watcher the harness reap will find.
  [ "$(ppid_of "$wpid")" != "$armpid" ] \
    || fail "watcher $wpid is still a ppid-descendant of arm $armpid - a harness reap takes it"

  harness_reap "$armpid"
  wait_for_pid_gone "$armpid" || fail "the arm survived its own reap"
  sleep 1
  is_live_non_zombie "$wpid" \
    || fail "the watcher died with its arm - supervision is silently off after every harness reap"
  watcher_healthy "$dir" \
    || fail "the surviving watcher no longer passes the production liveness gate"
  pass "a hosted watcher survives the harness reap that walks its arm's descendants"
}

test_hosted_watcher_survives_a_process_group_kill() {
  local dir armout armpid wpid pgid
  dir=$(make_arm_case pgroup)
  armout="$dir/arm.out"
  set_mode "$dir" hold
  # Its own session, so the group kill below is a real one and cannot reach this runner.
  ( exec setsid env FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
      FM_WATCH_HOST="$ARM_HOST" FM_ARM_CONFIRM_TIMEOUT=6 FM_ARM_ATTACH_POLL=0.1 \
      "$dir/bin/fm-watch-arm.sh" ) > "$armout" 2>&1 &
  armpid=$(wait_for_marker_pid "$dir") || fail "arm never recorded itself: $(cat "$armout")"
  wait_for_text "$armout" 'watcher: started pid=' \
    || fail "arm never confirmed a hosted watcher: $(cat "$armout")"
  wpid=$(confirmed_watcher_pid "$armout")
  pgid=$(pgid_of "$armpid")

  [ -n "$pgid" ] || fail "could not read the arm's process group"
  [ "$pgid" != "$(pgid_of $$)" ] \
    || fail "refusing to group-kill: the arm shares this runner's process group"
  kill -TERM -"$pgid" 2>/dev/null || true
  wait_for_pid_gone "$armpid" || fail "the arm survived a kill aimed at its own group"
  sleep 1
  is_live_non_zombie "$wpid" || fail "a process-group kill reached the watcher (F2 regression)"
  pass "a hosted watcher still survives a process-group kill of its arm"
}

test_a_second_arm_starts_no_second_watcher() {
  local dir armout secondout armpid secondpid runs
  dir=$(make_arm_case singleton)
  armout="$dir/arm.out"
  secondout="$dir/arm2.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' \
    || fail "arm never confirmed a hosted watcher: $(cat "$armout")"
  run_arm_bg "$dir" "$secondout"
  secondpid=$ARM_PID
  wait_for_text "$secondout" 'watcher: standby' \
    || fail "the second arm did not stand by for the live one: $(cat "$secondout")"
  is_live_non_zombie "$secondpid" \
    || fail "the second arm EXITED - that exit is a wake carrying no news: $(cat "$secondout")"
  runs=$(watcher_runs "$dir")
  [ "$runs" = 1 ] || fail "two arms produced $runs watchers for one home"
  [ "$(watcher_windows_of "$dir")" = 1 ] \
    || fail "one home has $(watcher_windows_of "$dir") watcher windows"
  is_live_non_zombie "$armpid" || fail "the incumbent arm died when a second one ran"
  pass "a second arm stands by rather than hosting a second watcher for the same home"
}

# The case the OWNER CLAIM exists for, and the only one that fails without it.
# Deciding "is this watcher already someone's?" used to mean reading its ppid: a
# watcher whose parent is a live arm belongs to that arm. A HOSTED watcher's parent
# is the tmux server, so that proxy answers "unowned" for every watcher there is, and
# a second arm that cannot see the incumbent's marker adopts a watcher already being
# supervised. Two arms on one watcher is the duplicate that multiplied every wake.
# The marker is removed to force the decision down to the watcher-ownership test
# instead of stopping at "a live peer arm holds the marker".
test_a_second_arm_does_not_adopt_a_hosted_watcher_a_live_arm_owns() {
  local dir armout secondout armpid secondpid runs
  dir=$(make_arm_case claimed)
  armout="$dir/arm.out"
  secondout="$dir/arm2.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' \
    || fail "arm never confirmed a hosted watcher: $(cat "$armout")"
  rm -f "$dir/state/.watch.arming"
  run_arm_bg "$dir" "$secondout"
  secondpid=$ARM_PID
  wait_for_text "$secondout" "watcher: standby - supervision held by arm pid=$armpid" \
    || fail "the second arm did not stand by for the arm that owns the hosted watcher: $(cat "$secondout")"
  grep -qF 'watcher: attached' "$secondout" \
    && fail "the second arm ADOPTED a watcher another arm is supervising: $(cat "$secondout")"
  runs=$(watcher_runs "$dir")
  [ "$runs" -eq 1 ] || fail "the second arm left an extra watcher behind (runs=$runs)"
  [ "$(watcher_windows_of "$dir")" = 1 ] \
    || fail "one home has $(watcher_windows_of "$dir") watcher windows"
  is_live_non_zombie "$armpid" || fail "the incumbent arm died when a second one ran"
  pass "a second arm stands by rather than adopting the hosted watcher a live arm owns"
}

test_supervision_live_is_truthful_while_the_arm_is_gone() {
  local dir armout armpid wpid out
  dir=$(make_arm_case truthful)
  armout="$dir/arm.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' \
    || fail "arm never confirmed a hosted watcher: $(cat "$armout")"
  wpid=$(confirmed_watcher_pid "$armout")

  out=$(supervision_live "$dir")
  case "$out" in *"watcher: live pid=$wpid"*) ;; *) fail "live watcher read as: $out" ;; esac

  # Orphaned: the arm is gone, the watcher still holds this home's lock. Supervision is
  # genuinely UP, and reporting DOWN here is what makes firstmate arm a duplicate.
  harness_reap "$armpid"
  wait_for_pid_gone "$armpid" || fail "the arm survived its own reap"
  out=$(supervision_live "$dir")
  case "$out" in *"watcher: live pid=$wpid"*) ;; *) fail "orphaned but live watcher read as: $out" ;; esac

  # Killed: the lock's holder is gone, so supervision is off and must say so.
  kill -TERM "$wpid" 2>/dev/null || true
  wait_for_pid_gone "$wpid" || fail "the watcher ignored TERM"
  out=$(supervision_live "$dir")
  case "$out" in *'watcher: DOWN'*) ;; *) fail "dead watcher read as: $out" ;; esac
  pass "fm-supervision-live.sh stays truthful when the watcher outlives its arm"
}

test_supervision_live_is_down_after_a_normal_wake() {
  local dir armout out
  dir=$(make_arm_case normal-exit)
  armout="$dir/arm.out"
  set_mode "$dir" wake
  run_arm_bg "$dir" "$armout"
  wait_for_text "$armout" 'stale: fm-probe' \
    || fail "the arm did not propagate the hosted watcher's wake: $(cat "$armout")"
  wait_for_pid_gone "$ARM_PID" || fail "the arm did not exit on a wake"
  out=$(supervision_live "$dir")
  case "$out" in *'watcher: DOWN'*) ;; *) fail "ended cycle read as: $out" ;; esac
  pass "a cycle that ended on a wake reads as DOWN, not as a live orphan"
}

test_a_wake_raised_after_the_arm_is_gone_still_drains() {
  local dir armout armpid wpid queue drained
  dir=$(make_arm_case orphan-wake)
  armout="$dir/arm.out"
  queue="$dir/state/.wake-queue"
  set_mode "$dir" holdwake
  run_arm_bg "$dir" "$armout"
  armpid=$ARM_PID
  wait_for_text "$armout" 'watcher: started pid=' \
    || fail "arm never confirmed a hosted watcher: $(cat "$armout")"
  wpid=$(confirmed_watcher_pid "$armout")

  harness_reap "$armpid"
  wait_for_pid_gone "$armpid" || fail "the arm survived its own reap"
  is_live_non_zombie "$wpid" || fail "the watcher died with its arm"

  # The watcher raises its wake with no arm left to print it. The durable queue is the
  # path that must carry it, and enqueue-before-print is what makes that safe.
  kill -TERM "$wpid" 2>/dev/null || true
  wait_for_pid_gone "$wpid" || fail "the watcher ignored TERM"
  grep -q 'fm-probe' "$queue" 2>/dev/null \
    || fail "the wake never reached the durable queue: $(cat "$queue" 2>/dev/null)"
  drained=$(FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    "$dir/bin/fm-wake-drain.sh" 2>&1)
  case "$drained" in
    *'stale: fm-probe'*) ;;
    *) fail "the drained record lost its payload: $drained" ;;
  esac
  [ -s "$queue" ] && fail "the queue was not emptied by the drain"
  pass "a wake raised after the arm is gone still reaches the durable queue and drains intact"
}

# A watcher's window has to close ITSELF. The arm that opened it is usually gone by the
# time the watcher ends, so there is nobody left to reap it, and under `remain-on-exit`
# a finished pane stays dead in place rather than closing. Un-fixed, this is one dead
# window per relaunch in a session that lives as long as the home does.
test_a_finished_watcher_leaves_no_window_and_no_temp_files() {
  local dir armout wpid i left temps
  dir=$(make_arm_case window-reap)
  armout="$dir/arm.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  wait_for_text "$armout" 'watcher: started pid=' \
    || fail "arm never confirmed a hosted watcher: $(cat "$armout")"
  wpid=$(confirmed_watcher_pid "$armout")
  [ "$(watcher_windows_of "$dir")" = 1 ] || fail "the watcher is not in a window of its own"

  # Kill the ARM first, so nothing but the launcher is left to clean up after the
  # watcher - which is the state every reaped arm leaves behind.
  harness_reap "$ARM_PID"
  wait_for_pid_gone "$ARM_PID" || fail "the arm survived its own reap"
  kill -TERM "$wpid" 2>/dev/null || true
  wait_for_pid_gone "$wpid" || fail "the watcher ignored TERM"

  i=0
  while [ "$i" -lt 50 ]; do
    [ "$(watcher_windows_of "$dir")" = 0 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  left=$(watcher_windows_of "$dir")
  [ "$left" = 0 ] \
    || fail "the finished watcher left $left window(s) behind: $(tmux list-panes -a -F '#{session_name}:#{window_name} dead=#{pane_dead}' 2>&1)"
  # The launcher outlives the arm, so it is the last thing that could write to
  # state/ - and by then nothing is left to read what it writes. Anything it leaves
  # is permanent: no arm globs these names, so they accumulate one set per reap.
  temps=
  for i in "$dir"/state/.watch-arm-output*; do
    [ -e "$i" ] && temps="$temps $i"
  done
  [ -z "$temps" ] \
    || fail "the reaped arm's hosted watcher left temp files nothing will ever remove: $temps"
  pass "a finished watcher leaves neither its window nor a temp file behind, with no arm left to reap either"
}

test_the_watcher_launcher_is_readable_only_by_its_owner() {
  local dir armout f mode found=
  dir=$(make_arm_case launcher-mode)
  armout="$dir/arm.out"
  set_mode "$dir" hold
  run_arm_bg "$dir" "$armout"
  wait_for_text "$armout" 'watcher: started pid=' \
    || fail "arm never confirmed a hosted watcher: $(cat "$armout")"
  for f in "$dir"/state/.watch-arm-output*.host.sh; do
    [ -e "$f" ] || continue
    found=$f
    mode=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)
    [ "$mode" = 700 ] \
      || fail "the launcher is mode $mode - it carries every exported FM_* value, PATH, HOME and TMPDIR into a file other users on this box can read"
  done
  [ -n "$found" ] || fail "no launcher on disk, so hosting did not run and this asserts nothing"
  kill -TERM "$(confirmed_watcher_pid "$armout")" 2>/dev/null || true
  pass "the watcher launcher is readable only by its owner"
}
test_two_homes_get_their_own_watcher_sessions() {
  local a b aout bout awpid bwpid asess bsess
  # Same basename, different paths: the basename alone cannot tell these two apart,
  # so the assertion below is on the digest over the full FM_HOME - the thing that
  # actually keeps two homes off one session - and not on a name that differs anyway.
  a=$(make_arm_case one/home)
  b=$(make_arm_case two/home)
  aout="$a/arm.out"
  bout="$b/arm.out"
  set_mode "$a" hold
  set_mode "$b" hold
  run_arm_bg "$a" "$aout"
  wait_for_text "$aout" 'watcher: started pid=' || fail "home A never confirmed: $(cat "$aout")"
  run_arm_bg "$b" "$bout"
  wait_for_text "$bout" 'watcher: started pid=' || fail "home B never confirmed: $(cat "$bout")"
  awpid=$(confirmed_watcher_pid "$aout")
  bwpid=$(confirmed_watcher_pid "$bout")
  [ "$awpid" != "$bwpid" ] || fail "two homes ended up sharing one watcher"

  asess=$(watcher_panes_of "$a" | head -1)
  bsess=$(watcher_panes_of "$b" | head -1)
  [ -n "$asess" ] && [ -n "$bsess" ] \
    || fail "a home's watcher is not in a tmux session at all (a=$asess, b=$bsess)"
  [ "$asess" != "$bsess" ] \
    || fail "both homes landed in the same watcher session ($asess) - the FM_HOME digest did not separate two homes sharing a basename"
  # The crew's namespace is fm-<id> windows in the crew's session. A watcher window
  # must never land there, and these are in sessions of their own.
  tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null \
    | grep -v '^fm-watch-.*:watcher$' | grep -q . \
    && fail "hosting created a window outside its own watcher session: $(tmux list-windows -a -F '#{session_name}:#{window_name}')"

  # Independent lifetimes: one home's watcher ending leaves the other's alone.
  kill -TERM "$awpid" 2>/dev/null || true
  wait_for_pid_gone "$awpid" || fail "home A's watcher ignored TERM"
  is_live_non_zombie "$bwpid" || fail "stopping home A's watcher took home B's with it"
  watcher_healthy "$b" || fail "home B lost supervision when home A's watcher stopped"
  pass "two homes on one host get their own watcher session and neither uses the crew namespace"
}

test_hosted_watcher_survives_a_harness_reap
test_hosted_watcher_survives_a_process_group_kill
test_a_second_arm_starts_no_second_watcher
test_a_second_arm_does_not_adopt_a_hosted_watcher_a_live_arm_owns
test_supervision_live_is_truthful_while_the_arm_is_gone
test_supervision_live_is_down_after_a_normal_wake
test_a_wake_raised_after_the_arm_is_gone_still_drains
test_a_finished_watcher_leaves_no_window_and_no_temp_files
test_the_watcher_launcher_is_readable_only_by_its_owner
test_two_homes_get_their_own_watcher_sessions
