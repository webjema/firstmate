#!/usr/bin/env bash
# Behavior tests for session-provider split-brain detection: the tmux adapter's
# server-count predicate, the detail line it composes, and bootstrap's
# SESSION_SPLIT: report.
#
# THE PREDICATE IS THE POINT. A tmux server keeps the argv of the client command
# that spawned it, so `pgrep -x -f 'tmux: server'` matches nothing and answers a
# confident 0 on a box that is actually split - which is worse than having no
# check at all. Case (a) runs a REAL decoy server and asserts its pid is in the
# predicate's output; that assertion is exactly what fails if someone
# reintroduces the -f.
#
# The decoy is isolated twice over - a private TMUX_TMPDIR and a private -L
# socket - so it never reaches the host's real sessions, and the assertion is
# membership of a known pid rather than a total count, so a suite running in
# parallel with it cannot make it flaky.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-tmux-split-tests)

DECOY_SOCKET=
REAL_TMUX=$(command -v tmux || true)
DECOY_TMPDIR="$TMP_ROOT/decoy-tmux-tmpdir"

kill_decoy() {
  [ -n "$DECOY_SOCKET" ] || return 0
  TMUX_TMPDIR="$DECOY_TMPDIR" "$REAL_TMUX" -L "$DECOY_SOCKET" kill-server >/dev/null 2>&1 || true
}

cleanup() {
  kill_decoy
  fm_test_cleanup
}
trap cleanup EXIT

# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

# --- (a) the predicate counts a real server the argv-matching form misses -----

if [ -z "$REAL_TMUX" ]; then
  echo "skip: tmux not found - (a) real-server predicate case"
else
  mkdir -p "$DECOY_TMPDIR"
  chmod 700 "$DECOY_TMPDIR"
  DECOY_SOCKET="fm-split-decoy-$$"
  # The decoy's session runs a bounded sleep, so the server exits on its own if
  # this test is SIGKILLed past its trap (fm-test.sh's per-test timeout can do
  # that) - a test must not be able to leave a live tmux server on the box.
  TMUX_TMPDIR="$DECOY_TMPDIR" "$REAL_TMUX" -L "$DECOY_SOCKET" \
    new-session -d -s decoy 'sleep 60' \
    || fail "(a) could not start the decoy tmux server"
  decoy_pid=$(TMUX_TMPDIR="$DECOY_TMPDIR" "$REAL_TMUX" -L "$DECOY_SOCKET" display-message -p '#{pid}')
  [ -n "$decoy_pid" ] || fail "(a) decoy server reported no pid"

  pids=$(fm_backend_tmux_server_pids)
  printf '%s\n' "$pids" | grep -qx "$decoy_pid" \
    || fail "(a) fm_backend_tmux_server_pids missed the live decoy server (pid $decoy_pid); a comm match is required, an argv match finds nothing"$'\n'"--- pids ---"$'\n'"$pids"

  kill_decoy
  # The server is gone the moment kill-server returns; nothing to wait for.
  pids=$(fm_backend_tmux_server_pids)
  printf '%s\n' "$pids" | grep -qx "$decoy_pid" \
    && fail "(a) fm_backend_tmux_server_pids still lists pid $decoy_pid after its server was killed"
  DECOY_SOCKET=
  pass "(a) the predicate counts a live tmux server by comm, and drops it when it dies"
fi

# --- fakes for the report and bootstrap cases --------------------------------
#
# From here on every case is driven by a fake pgrep/tmux pair: the split states
# worth pinning (two servers, an unreachable socket) must never be staged with
# real servers on a box the captain is working on.

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/pgrep" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_FAKE_TMUX_SERVER_PIDS:-}" ] || exit 1
printf '%s\n' $FM_FAKE_TMUX_SERVER_PIDS
exit 0
SH
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = display-message ]; then
  [ "${FM_FAKE_TMUX_NO_SERVER:-0}" = 1 ] && exit 1
  case "${3:-}" in
    '#{pid}') printf '%s\n' "${FM_FAKE_TMUX_OWNER_PID:-3097422}" ;;
    '#{socket_path}') printf '%s\n' "${FM_FAKE_TMUX_SOCKET:-/tmp/tmux-1001/default}" ;;
  esac
  exit 0
fi
exit 0
SH
chmod +x "$FAKEBIN/pgrep" "$FAKEBIN/tmux"
PATH="$FAKEBIN:$PATH"
export PATH

# --- (b) the report says nothing unless there is a split ---------------------

out=$(FM_FAKE_TMUX_SERVER_PIDS="3097422" fm_backend_tmux_server_split)
[ -z "$out" ] || fail "(b) one server must be silent, got: $out"
out=$(FM_FAKE_TMUX_SERVER_PIDS="" fm_backend_tmux_server_split)
[ -z "$out" ] || fail "(b) no server at all must be silent, got: $out"
pass "(b) a single tmux server, and no server at all, report nothing"

# --- (c) a split names the count, the socket owner, and the orphans ----------

out=$(FM_FAKE_TMUX_SERVER_PIDS="3097422 228870" fm_backend_tmux_server_split)
assert_contains "$out" "2 tmux servers" "(c) the report must say how many servers are running"
assert_contains "$out" "pid 3097422 answers at /tmp/tmux-1001/default" "(c) the report must name the pid that answers at the socket path"
assert_contains "$out" "pid(s) 228870 do not" "(c) the report must name the servers that do not answer there"
assert_contains "$out" "invisible to every liveness read" "(c) the report must say what the unreachable servers' windows cost"
# The predicate inspects no sockets, so it cannot know an unreachable server is
# an orphan rather than a deliberate `tmux -L` one - and must not say so.
assert_not_contains "$out" "orphan" "(c) the report must not call an unreachable server an orphan"
pass "(c) a split reports the count, the answering pid, and what the rest cost, without assigning blame"

# --- (d) a socket nothing answers at leaves the fleet with no reachable server -

out=$(FM_FAKE_TMUX_SERVER_PIDS="3097422 228870" FM_FAKE_TMUX_NO_SERVER=1 \
  fm_backend_tmux_server_split)
assert_contains "$out" "none of them answers at the socket path" \
  "(d) with nothing answering the report must say so"
assert_contains "$out" "pid(s) 3097422 228870 are all invisible" \
  "(d) with nothing answering every pid must be reported as unreachable"
# The socket path is only ever quoted from tmux itself; with no server to ask,
# a guessed path would be presented to the captain as fact.
assert_not_contains "$out" "/tmp/tmux-" "(d) the report must not guess a socket path it could not read"
pass "(d) an unanswered socket path reports every server as unreachable"

# --- (e) bootstrap prints SESSION_SPLIT only on a split, detect-only included -

run_bootstrap() {
  local pids=$1 home
  home="$TMP_ROOT/home"
  mkdir -p "$home"
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TMUX_SERVER_PIDS="$pids" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^SESSION_SPLIT:' || true
}

out=$(run_bootstrap "3097422")
[ -z "$out" ] || fail "(e) bootstrap must stay silent with one tmux server, got: $out"
out=$(run_bootstrap "3097422 228870")
assert_contains "$out" "SESSION_SPLIT: 2 tmux servers" "(e) bootstrap did not report a split"
assert_contains "$out" "pid 3097422 answers at" "(e) bootstrap's line did not name the answering server"
pass "(e) bootstrap reports a split, and only a split, in read-only detect mode too"
