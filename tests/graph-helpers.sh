#!/usr/bin/env bash
# tests/graph-helpers.sh - fake codebase-memory CLI for the knowledge-graph suites.
#
# Source alongside tests/lib.sh from any test that exercises bin/fm-graph-lib.sh's
# callers (bin/fm-graph-reindex.sh, bin/fm-fleet-sync.sh, bin/fm-brief.sh). It is a
# helper file rather than a per-suite mock because three suites need the same stub,
# and a stub copied three times drifts three ways.
#
# The stub stands in for `codebase-memory-mcp cli <tool> --flag value ...`. Point
# FM_GRAPH_CLI at it, then drive it with these run-time env vars:
#   FM_STUB_PROJECTS  file holding the list_projects JSON payload (see fm_graph_stub_projects)
#   FM_STUB_LOG       file the stub appends one line of "<tool> <args...>" to per call
#   FM_STUB_FAIL      space/comma list of tools that exit 1 instead of answering
#   FM_STUB_NOISE     non-empty: emit non-JSON leading lines on stdout before the payload,
#                     mimicking the real binary's mem.init log and deprecation warning
#   FM_STUB_SLEEP     seconds to stall before answering (for timeout bounding tests)

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm_graph_stub <dir>: write the stub into <dir> and echo its path.
fm_graph_stub() {
  local dir=$1 stub="$1/codebase-memory-stub"
  mkdir -p "$dir"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
# Fake codebase-memory-mcp: `<stub> cli <tool> [--flag value ...]`.
set -u
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
  echo "warning: passing raw JSON positionally is deprecated"
fi
case "$tool" in
  list_projects)
    cat "${FM_STUB_PROJECTS:-/dev/null}"
    ;;
  index_repository)
    name=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '{"project":"%s","nodes":4321,"edges":9876,"status":"indexed"}\n' "$name"
    ;;
  *) echo '{}' ;;
esac
SH
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

# fm_graph_stub_projects <file> [<name> <root>]...: write a list_projects payload
# holding the given (name, root) pairs. root_path and git.canonical_root both carry
# <root>, matching what the real binary reports for a non-worktree clone.
fm_graph_stub_projects() {
  local file=$1 first=1
  shift
  {
    printf '{"projects":['
    while [ $# -ge 2 ]; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"name":"%s","root_path":"%s","git":{"is_worktree":false,"canonical_root":"%s","branch":"main","head_sha":"deadbeef"},"nodes":4321}' "$1" "$2" "$2"
      shift 2
    done
    printf ']}\n'
  } > "$file"
}

# fm_graph_stub_projects_canonical_only <file> <name> <root>: a payload whose
# root_path is a DIFFERENT path (a worktree) and whose git.canonical_root is <root>,
# so the lookup must match on the canonical root rather than root_path alone.
fm_graph_stub_projects_canonical_only() {
  local file=$1 name=$2 root=$3
  printf '{"projects":[{"name":"%s","root_path":"%s/some-worktree","git":{"is_worktree":true,"canonical_root":"%s","branch":"main","head_sha":"deadbeef"},"nodes":4321}]}\n' \
    "$name" "$root" "$root" > "$file"
}
