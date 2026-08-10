#!/usr/bin/env bash
# tests/graph-helpers.sh - fake codebase-memory CLI for the knowledge-graph suites.
#
# Source alongside tests/lib.sh from any test that exercises bin/fm-graph-lib.sh's
# callers (bin/fm-graph-reindex.sh, bin/fm-fleet-sync.sh, bin/fm-brief.sh). It is a
# helper file rather than a per-suite mock because three suites need the same stub,
# and a stub copied three times drifts three ways.
#
# The stub stands in for `codebase-memory-mcp cli <tool> [json_args]`, the 0.8.1
# surface. It REJECTS a --flag argument exactly the way the real binary does, so a
# regression back to the flag form fails here instead of silently on the fleet.
# Point FM_GRAPH_CLI at it, then drive it with these run-time env vars:
#   FM_STUB_PROJECTS  file holding the list_projects JSON payload (see fm_graph_stub_projects)
#   FM_STUB_LOG       file the stub appends one line of "<tool> <args...>" to per call
#   FM_STUB_FAIL      space/comma list of tools that exit 1 instead of answering
#   FM_STUB_NOISE     non-empty: emit non-JSON leading lines on stdout before the payload,
#                     mimicking the real binary's chatty progress logging
#   FM_STUB_SLEEP     seconds to stall before answering (for timeout bounding tests)
#   FM_STUB_INDEX_PROJECT  project name index_repository claims to have written, instead of
#                     the one it would derive from repo_path (drives the mismatch path)
#   FM_STUB_INDEX_NO_PROJECT  non-empty: omit `project` from the index_repository response
#                     entirely, the way a future binary that stopped reporting it would
#   FM_STUB_INDEX_STATUS   status index_repository reports, instead of "indexed"
#
# Like the real 0.8.1 binary, index_repository takes NO name and never consults the
# recorded entry: it DERIVES the project from the repo_path it was handed. Modelling
# that faithfully is what lets a test tell a refresh that landed on the recorded
# entry from one that landed elsewhere - a stub that looked the path up instead
# would answer with the recorded name for a path the binary would slug differently,
# and so would report a landing the binary never performs.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm_graph_derived_name <path>: the project name the real binary derives for <path>.
# 0.8.1 keeps [A-Za-z0-9._], turns every other character into a dash, collapses runs
# of dashes, and trims the ends - so /home/u/projects/x becomes home-u-projects-x,
# and a path holding a space or a quote slugs rather than being rejected. Probed
# against 0.8.1; docs/graph-cli-backend.md holds the evidence.
fm_graph_derived_name() {
  local s
  s=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._' '-' | tr -s '-')
  s=${s#-}
  printf '%s\n' "${s%-}"
}

# fm_graph_stub <dir>: write the stub into <dir> and echo its path.
fm_graph_stub() {
  local dir=$1 stub="$1/codebase-memory-stub"
  mkdir -p "$dir"
  {
    cat <<'SH'
#!/usr/bin/env bash
# Fake codebase-memory-mcp: `<stub> cli <tool> [json_args]` (the 0.8.1 surface).
set -u
SH
    # The stub gets the derivation rule as the definition above rather than a second
    # copy of it: two copies of a rule about an external binary drift apart, and one
    # of them is then a belief nothing re-verifies.
    declare -f fm_graph_derived_name
    cat <<'SH'
tool=${2:-}
shift 2 2>/dev/null || true
[ -z "${FM_STUB_LOG:-}" ] || printf '%s %s\n' "$tool" "$*" >> "$FM_STUB_LOG"
[ -z "${FM_STUB_SLEEP:-}" ] || sleep "$FM_STUB_SLEEP"
case " ${FM_STUB_FAIL:-} " in
  *[\ ,]"$tool"[\ ,]*) echo "stub: $tool failed" >&2; exit 1 ;;
esac
# The real binary logs to stderr; FM_STUB_NOISE additionally puts non-JSON lines on
# stdout, which the parser must tolerate rather than assume away.
echo "level=info msg=mem.init budget_mb=3904 total_ram_mb=15617" >&2
if [ -n "${FM_STUB_NOISE:-}" ]; then
  echo "level=info msg=mem.init budget_mb=3904 total_ram_mb=15617"
  echo "level=info msg=pipeline.discover files=0 elapsed_ms=0"
fi
# 0.8.1 takes ONE positional JSON object and knows no flags at all: it reads a
# --flag as a tool argument it cannot parse and dies with "repo_path is required".
# Reproducing that here is the point of the stub - it is what makes a regression to
# the flag form a red test rather than a fortnight of silent staleness.
args=${1:-}
case "$args" in
  --*) echo "repo_path is required" >&2; exit 1 ;;
esac
if [ -n "$args" ] && ! printf '%s' "$args" | jq -e . >/dev/null 2>&1; then
  echo "invalid json argument" >&2
  exit 1
fi
case "$tool" in
  list_projects)
    cat "${FM_STUB_PROJECTS:-/dev/null}"
    ;;
  index_repository)
    repo_path=$(printf '%s' "$args" | jq -r '.repo_path // empty' 2>/dev/null)
    if [ -z "$repo_path" ]; then
      echo "repo_path is required" >&2
      exit 1
    fi
    # No name argument exists, and the binary never looks the path up: it slugs the
    # path it was handed. So does this, which is why a lookup that matched on some
    # OTHER path shows up here as a landing on a different project.
    project=${FM_STUB_INDEX_PROJECT:-$(fm_graph_derived_name "$repo_path")}
    if [ -n "${FM_STUB_INDEX_NO_PROJECT:-}" ]; then
      jq -nc --arg status "${FM_STUB_INDEX_STATUS:-indexed}" \
        '{nodes: 4321, edges: 9876, status: $status}'
    else
      jq -nc --arg project "$project" --arg status "${FM_STUB_INDEX_STATUS:-indexed}" \
        '{project: $project, nodes: 4321, edges: 9876, status: $status}'
    fi
    ;;
  *) echo '{}' ;;
esac
SH
  } > "$stub"
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

# fm_graph_stub_projects <file> [<name> <root>]...: write a list_projects payload
# holding the given (name, root) pairs. root_path and git.canonical_root both carry
# <root>, matching what the real binary reports for a non-worktree clone.
#
# BUILT WITH jq, for the same reason the code under test builds its arguments with
# jq: a root path holding a quote concatenates into a payload that is not JSON, and
# a fixture that cannot represent the awkward path is a fixture that cannot test it.
fm_graph_stub_projects() {
  local file=$1
  shift
  jq -n '{projects: []}' > "$file"
  while [ $# -ge 2 ]; do
    jq --arg name "$1" --arg root "$2" '
      .projects += [{
        name: $name,
        root_path: $root,
        git: {is_worktree: false, canonical_root: $root, branch: "main", head_sha: "deadbeef"},
        nodes: 4321
      }]' "$file" > "$file.next"
    mv "$file.next" "$file"
    shift 2
  done
}

# fm_graph_stub_projects_canonical_only <file> <name> <root>: a payload whose
# root_path is a DIFFERENT path (a worktree) and whose git.canonical_root is <root>,
# so the lookup must match on the canonical root rather than root_path alone.
fm_graph_stub_projects_canonical_only() {
  local file=$1 name=$2 root=$3
  jq -n --arg name "$name" --arg root "$root" '
    {projects: [{
      name: $name,
      root_path: ($root + "/some-worktree"),
      git: {is_worktree: true, canonical_root: $root, branch: "main", head_sha: "deadbeef"},
      nodes: 4321
    }]}' > "$file"
}
