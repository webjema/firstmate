#!/usr/bin/env bash
# fm-repo-url.sh - ask whether two remote URLs are the same repository, from a shell.
#
# A thin command over bin/fm-repo-url-lib.sh, which owns the canonical form and the
# full list of what is deliberately not normalised. Read that header before relying on
# an answer here.
#
# Usage:
#   fm-repo-url.sh canonical <url>          print <url>'s repository identity
#   fm-repo-url.sh same <url-a> <url-b>     exit 0 when both name one repository
#   fm-repo-url.sh pool-key <clone-dir>     print firstmate's pool key for a clone
#
# `canonical` prints an IDENTITY, never a fetchable URL - do not pass it to git clone.
# `pool-key` answers "would these two clones share one of firstmate's warm locks";
# it is NOT treehouse's pool directory name, and fm-pool-lib.sh's fm_pool_key says why.
#
# Exit status: 0 on success or a match, 1 when `same` finds two different repositories,
# 2 for a usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-repo-url-lib.sh
. "$SCRIPT_DIR/fm-repo-url-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  canonical)
    [ $# -eq 2 ] || { usage >&2; exit 2; }
    fm_repo_url_canonical "$2"
    printf '\n'
    ;;
  same)
    [ $# -eq 3 ] || { usage >&2; exit 2; }
    fm_repo_url_same "$2" "$3"
    ;;
  pool-key)
    [ $# -eq 2 ] || { usage >&2; exit 2; }
    [ -d "$2" ] || { echo "error: $2 is not a directory" >&2; exit 2; }
    # shellcheck source=bin/fm-pool-lib.sh
    . "$SCRIPT_DIR/fm-pool-lib.sh"
    fm_pool_key "$(cd "$2" && pwd -P)"
    printf '\n'
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
