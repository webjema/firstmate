#!/usr/bin/env bash
# Tests for fm_pool_read in bin/fm-pool-lib.sh - reading a treehouse pool without
# parsing the human `treehouse status` table, which changes between releases.
#
# Every case runs against a real pool fixture: a scratch repo whose slots are real
# linked worktrees under <tmp>/th-root/pool/<n>/proj, beside a hand-written
# treehouse-state.json. Never the operator's ~/.treehouse.
#
#   (a) treehouse v2 (no --json): state from the state file, git and the process table
#   (b) a recorded owner is in-use only while it is still THAT process
#   (c) destroying entries and vanished slots are not slots
#   (d) a project with no slots reads as an empty pool
#   (e) a state file in an unknown shape fails loudly, never guessed
#   (f) treehouse v3+: `status --json` is the source, and malformed output fails loudly
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
# shellcheck source=bin/fm-pool-lib.sh disable=SC1091
. "$ROOT/bin/fm-pool-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pool-read)
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
BG_PIDS=()
cleanup() {
  local p
  for p in "${BG_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  fm_test_cleanup
}
trap cleanup EXIT

# new_case <name> <v2|v3>: a repo, an empty pool dir, and a treehouse stub that
# logs every call. v2's help names no --json; v3's does and answers it from TH_JSON.
new_case() {
  local c="$TMP_ROOT/$1"
  mkdir -p "$c/fakebin" "$c/th-root/pool"
  fm_git_init_commit "$c/proj"
  cat > "$c/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$c/th-calls.log"
case "\$*" in
  'status --help') printf '  -h, --help   help for status\n'
                   [ "$2" = v3 ] && printf '      --json   Print pool status as JSON\n' ;;
  'status --json') cat "$c/th.json" ;;
esac
exit 0
SH
  chmod +x "$c/fakebin/treehouse"
  printf '%s\n' "$c"
}

add_slot() {  # <case> <n> -> echoes the slot path
  local slot="$1/th-root/pool/$2/proj"
  mkdir -p "$(dirname "$slot")"
  git -C "$1/proj" worktree add -q --detach "$slot" 2>/dev/null
  printf '%s\n' "$slot"
}

read_pool() {  # <case> -> sets RC and ERR, leaves FM_POOL_* for assertions
  RC=0
  PATH="$1/fakebin:$PATH" fm_pool_read "$1/proj" 2>"$1/err" || RC=$?
  ERR=$(cat "$1/err")
}

row() {  # <name> <state> <path> [holder]
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}"
}

# --- (a) v2: every state derived without the table ---------------------------
C=$(new_case a v2)
S1=$(add_slot "$C" 1); S2=$(add_slot "$C" 2); S3=$(add_slot "$C" 3); S4=$(add_slot "$C" 4)
printf 'unsaved\n' > "$S2/wip.txt"
(cd "$S4" && exec sleep 300) & BG_PIDS+=("$!")
cat > "$C/th-root/pool/treehouse-state.json" <<JSON
{"worktrees":[
 {"name":"1","path":"$S1","created_at":"2026-01-01T00:00:00Z"},
 {"name":"2","path":"$S2","created_at":"2026-01-01T00:00:00Z"},
 {"name":"3","path":"$S3","created_at":"2026-01-01T00:00:00Z","leased":true,"lease_holder":"fm-warm-x","leased_at":"2026-01-01T00:00:00Z"},
 {"name":"4","path":"$S4","created_at":"2026-01-01T00:00:00Z"}]}
JSON
sleep 0.2
read_pool "$C"
expect_code 0 "$RC" "(a) a v2 pool reads ($ERR)"
WANT="$(row 1 available "$S1")
$(row 2 dirty "$S2")
$(row 3 leased "$S3" fm-warm-x)
$(row 4 in-use "$S4")"
[ "$FM_POOL_TABLE" = "$WANT"$'\n' ] \
  || fail "(a) v2 slot states"$'\n'"--- want ---"$'\n'"$WANT"$'\n'"--- got ---"$'\n'"$FM_POOL_TABLE"
[ "$FM_POOL_SLOTS" = 4 ] && [ "$FM_POOL_AVAILABLE" = 1 ] \
  || fail "(a) counts: slots=$FM_POOL_SLOTS available=$FM_POOL_AVAILABLE"
[ "$FM_POOL_DIR" = "$C/th-root/pool" ] || fail "(a) pool dir: $FM_POOL_DIR"
[ "$(cat "$C/th-calls.log")" = "status --help" ] \
  || fail "(a) on v2 only the help is asked - status itself writes state: $(cat "$C/th-calls.log")"
pass "(a) treehouse v2: available, dirty, leased and in-use come from state, git and the process table"

# --- (b) owner liveness is pid AND start time --------------------------------
C=$(new_case b v2)
S1=$(add_slot "$C" 1); S2=$(add_slot "$C" 2)
sleep 300 & OWNER=$!; BG_PIDS+=("$OWNER")
STARTED=$(date +%s%3N)
cat > "$C/th-root/pool/treehouse-state.json" <<JSON
{"worktrees":[
 {"name":"1","path":"$S1","created_at":"2026-01-01T00:00:00Z","owner_pid":$OWNER,"owner_started_at":$STARTED},
 {"name":"2","path":"$S2","created_at":"2026-01-01T00:00:00Z","owner_pid":$OWNER,"owner_started_at":$((STARTED - 3600000))}]}
JSON
read_pool "$C"
expect_code 0 "$RC" "(b) read ($ERR)"
assert_contains "$FM_POOL_TABLE" "$(row 1 in-use "$S1")" "(b) a live owner holds its slot"
assert_contains "$FM_POOL_TABLE" "$(row 2 available "$S2")" "(b) a recycled pid is not the owner"
pass "(b) a recorded owner holds its slot only while pid and start time both match"

# --- (c) destroying and vanished slots ----------------------------------------
C=$(new_case c v2)
S1=$(add_slot "$C" 1); S2=$(add_slot "$C" 2)
cat > "$C/th-root/pool/treehouse-state.json" <<JSON
{"worktrees":[
 {"name":"1","path":"$S1","created_at":"2026-01-01T00:00:00Z","destroying":true},
 {"name":"2","path":"$S2","created_at":"2026-01-01T00:00:00Z"},
 {"name":"9","path":"$C/th-root/pool/9/proj","created_at":"2026-01-01T00:00:00Z"}]}
JSON
read_pool "$C"
expect_code 0 "$RC" "(c) read ($ERR)"
[ "$FM_POOL_TABLE" = "$(row 2 available "$S2")"$'\n' ] || fail "(c) only slot 2 is a slot: $FM_POOL_TABLE"
pass "(c) destroying entries and vanished slot directories are skipped"

# --- (d) no slots --------------------------------------------------------------
C=$(new_case d v2)
read_pool "$C"
expect_code 0 "$RC" "(d) read ($ERR)"
[ "$FM_POOL_SLOTS" = 0 ] && [ -z "$FM_POOL_TABLE" ] && [ -z "$FM_POOL_DIR" ] \
  || fail "(d) a slotless project is an empty pool: slots=$FM_POOL_SLOTS dir=$FM_POOL_DIR"
[ ! -e "$HOME/.treehouse" ] || fail "(d) reading must not create a pool"
pass "(d) a project with no slots reads as an empty pool and creates nothing"

# --- (e) unknown state layouts ---------------------------------------------------
C=$(new_case e v2)
S1=$(add_slot "$C" 1)
STATE="$C/th-root/pool/treehouse-state.json"
for bad in \
  "{\"version\":4,\"worktrees\":[{\"name\":\"1\",\"path\":\"$S1\"}]}" \
  '{"worktrees":' \
  "{\"worktrees\":{\"name\":\"1\",\"path\":\"$S1\"}}" \
  '{"worktrees":[{"name":"1"}]}'; do
  printf '%s\n' "$bad" > "$STATE"
  read_pool "$C"
  expect_code 1 "$RC" "(e) state file $bad"
  assert_contains "$ERR" "unrecognised $STATE" "(e) the failure names the file for $bad"
  [ "$FM_POOL_SLOTS" = 0 ] && [ -z "$FM_POOL_TABLE" ] || fail "(e) nothing is reported from $bad"
done
pass "(e) a versioned, malformed or reshaped state file fails loudly instead of being guessed"

# --- (f) v3: status --json -------------------------------------------------------
C=$(new_case f v3)
S1=$(add_slot "$C" 1); S2=$(add_slot "$C" 2)
cat > "$C/th.json" <<JSON
[{"name":"1","path":"$S1","status":"available","branch":"","detached":true,"processes":[]},
 {"name":"2","path":"$S2","status":"leased","lease_id":"abc","lease_holder":"fm-warm-y","processes":[]}]
JSON
read_pool "$C"
expect_code 0 "$RC" "(f) a v3 pool reads ($ERR)"
[ "$FM_POOL_TABLE" = "$(row 1 available "$S1")
$(row 2 leased "$S2" fm-warm-y)"$'\n' ] || fail "(f) v3 rows: $FM_POOL_TABLE"
[ "$FM_POOL_AVAILABLE" = 1 ] && [ "$FM_POOL_DIR" = "$C/th-root/pool" ] \
  || fail "(f) available=$FM_POOL_AVAILABLE dir=$FM_POOL_DIR"
assert_not_contains "$(grep -vx 'status --help\|status --json' "$C/th-calls.log")" status \
  "(f) the human table is never asked for"
for bad in '{}' "[{\"name\":\"1\",\"status\":\"available\"}]" 'not json'; do
  printf '%s\n' "$bad" > "$C/th.json"
  read_pool "$C"
  expect_code 1 "$RC" "(f) --json output $bad"
  assert_contains "$ERR" "unrecognised treehouse status --json output" "(f) the failure says why for $bad"
done
pass "(f) treehouse v3+: status --json is read, and output of an unknown shape fails loudly"
