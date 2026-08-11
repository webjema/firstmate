#!/usr/bin/env bash
# Codebase drift metrics: a few cheap numbers per project, recorded over time.
#
# Usage: fm-code-metrics.sh record <project> [--note <text>]
#              measure the project's clone at HEAD, append a row, print the delta
#              against the previous row.
#        fm-code-metrics.sh show <project>
#              print the recorded history.
#        fm-code-metrics.sh delta <project>
#              print the delta between the last two rows without recording.
#
# WHY THIS EXISTS. A tending pass that reads code finds what is wrong in the slice
# it happens to read. It cannot see the thing that is usually worse: the codebase
# moving steadily in a direction nobody chose. Measured on optiroq 2026-08-10 -
# comment share of source lines was 16.9% in files older than 60 days, 27.9% in
# files newer than that, and 45.1% of the lines ADDED by the last twelve feature
# PRs. No single PR was unreasonable, every review passed, and nothing noticed.
# Only the trend showed it, and only because someone went looking by hand.
#
# So this records the trend instead. The absolute values matter less than the
# delta between two passes: a number that moved is a question worth asking, and a
# number that held is coverage nobody had to read code for.
#
# WHAT IT DELIBERATELY DOES NOT DO. It never fails, gates, or judges. There is no
# threshold in here and no exit code that means "too high" - a metric that blocks
# gets gamed or disabled, and every threshold anyone picked would be a guess. It
# reports; a person or a tending pass decides whether a move is drift or growth.
#
# `new_cmt%` is the leading indicator and the one to watch. Whole-tree `cmt%` lags
# by the size of the tree - optiroq's moved 11 points while newly added lines were
# already at 45% - so a drift caught in `cmt%` is a year of drift. Both are
# recorded because the pair is what tells you a trend from a level.
#
# LANGUAGE COVERAGE is by extension, two comment families: `//` and `/*...*/` for
# the C family, `#` for the shell/python/ruby/config family. A file whose
# extension is in neither is not counted at all rather than counted wrongly. A
# shebang reads as a comment; at one line per file that is not worth special-casing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# A file over this many lines is counted in `big`. Not a limit and not a warning -
# the count only earns its place by moving between passes.
BIG_FILE_LINES=${FM_METRICS_BIG_FILE_LINES:-400}

die() { echo "error: $*" >&2; exit 1; }

metrics_file() { printf '%s\n' "$DATA/reviews/$1/metrics.tsv"; }
repo_dir() { printf '%s\n' "$PROJECTS/$1"; }

git_r() { git -C "$REPO" "$@"; }

# --- what counts as source ---------------------------------------------------

# Tracked files only, so anything gitignored (vendor trees, build output) is out
# by construction. The explicit excludes below are for paths that ARE tracked but
# are not code anyone writes: minified bundles, lockfiles, snapshots.
source_files() {
  git_r ls-files \
    | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|java|go|rs|c|h|cc|cpp|hpp|cs|swift|kt|kts|scala|php|py|sh|bash|rb|pl)$' \
    | grep -vE '(^|/)(node_modules|dist|build|vendor|third_party|generated)/' \
    | grep -vE '\.(min|bundle)\.(js|css)$' \
    | grep -vE '(^|/)package-lock\.json$' \
    || true
}

is_test_path() {
  printf '%s' "$1" | grep -qE '(^|/)(tests?|__tests__|spec|e2e)/|(\.|_)(test|spec)\.[a-z]+$|(^|/)test_[^/]+\.py$'
}

# --- counting ----------------------------------------------------------------

# One awk pass over every file: code, comment and total lines, per family.
# Emits "code comment total" summed over the files handed to it.
# shellcheck disable=SC2016  # an awk program, not a shell string: it must not expand here.
COUNT_AWK='
function fam(f) {
  if (f ~ /\.(ts|tsx|js|jsx|mjs|cjs|java|go|rs|c|h|cc|cpp|hpp|cs|swift|kt|kts|scala|php)$/) return "c"
  if (f ~ /\.(py|sh|bash|rb|pl)$/) return "h"
  return ""
}
FNR == 1 { inblock = 0; family = fam(FILENAME) }
family == "" { next }
{
  line = $0
  gsub(/^[ \t]+/, "", line)
  if (line == "") next
  total++
  if (family == "c") {
    if (inblock) { comment++; if (line ~ /\*\//) inblock = 0; next }
    if (line ~ /^\/\*/) { comment++; if (line !~ /\*\//) inblock = 1; next }
    if (line ~ /^\/\// || line ~ /^\*/) { comment++; next }
    code++
    next
  }
  if (line ~ /^#/) { comment++; next }
  code++
}
END { printf "%d %d %d\n", code + 0, comment + 0, total + 0 }
'

# Added lines in a diff, split into code and comment the same way. Tracks the
# current file from the `+++ b/<path>` header so each hunk is read with its own
# language family; a `/dev/null` target (a deletion) parks the family as unknown.
# shellcheck disable=SC2016  # an awk program, not a shell string: it must not expand here.
DIFF_AWK='
function fam(f) {
  if (f ~ /\.(ts|tsx|js|jsx|mjs|cjs|java|go|rs|c|h|cc|cpp|hpp|cs|swift|kt|kts|scala|php)$/) return "c"
  if (f ~ /\.(py|sh|bash|rb|pl)$/) return "h"
  return ""
}
# Test and vendor paths are filtered HERE rather than by a pathspec on the diff:
# the file list is thousands of entries on a real project and would overrun the
# command line. Must stay in step with is_test_path and source_files above.
function skip(f) {
  if (f ~ /(^|\/)(tests?|__tests__|spec|e2e)\//) return 1
  if (f ~ /(\.|_)(test|spec)\.[a-zA-Z]+$/) return 1
  if (f ~ /(^|\/)test_[^\/]+\.py$/) return 1
  if (f ~ /(^|\/)(node_modules|dist|build|vendor|third_party|generated)\//) return 1
  if (f ~ /\.(min|bundle)\.(js|css)$/) return 1
  return 0
}
/^\+\+\+ / {
  path = substr($0, 7)
  sub(/^b\//, "", path)
  family = (path == "/dev/null" || skip(path)) ? "" : fam(path)
  inblock = 0
  next
}
/^--- / { next }
/^@@/ { inblock = 0; next }
family == "" { next }
/^\+/ {
  line = substr($0, 2)
  gsub(/^[ \t]+/, "", line)
  if (line == "") next
  if (family == "c") {
    if (inblock) { comment++; if (line ~ /\*\//) inblock = 0; next }
    if (line ~ /^\/\*/) { comment++; if (line !~ /\*\//) inblock = 1; next }
    if (line ~ /^\/\// || line ~ /^\*/) { comment++; next }
    code++
    next
  }
  if (line ~ /^#/) { comment++; next }
  code++
}
END { printf "%d %d\n", code + 0, comment + 0 }
'

pct() { # $1 = part, $2 = whole -> one decimal, or "-" when there is nothing to divide
  if [ "${2:-0}" -le 0 ]; then printf '%s' '-'; return; fi
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", 100 * a / b }'
}

# --- measurement -------------------------------------------------------------

measure() { # sets the METRIC_* globals for $REPO at HEAD
  local all prod test_files
  all=$(source_files)
  [ -n "$all" ] || die "no recognised source files in $REPO"

  prod=""
  test_files=""
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_test_path "$f"; then test_files="$test_files$f"$'\n'; else prod="$prod$f"$'\n'; fi
  done <<EOF
$all
EOF

  # xargs may split a big file list across several awk runs, each printing its own
  # END line, so the totals are summed rather than read off the first one.
  local counts
  counts=$(cd "$REPO" && printf '%s' "$prod" | sed '/^$/d' | tr '\n' '\0' \
           | xargs -0 -r awk "$COUNT_AWK" 2>/dev/null \
           | awk '{ c += $1; m += $2; t += $3 } END { printf "%d %d %d\n", c + 0, m + 0, t + 0 }')
  [ -n "$counts" ] || counts="0 0 0"
  METRIC_CODE=$(printf '%s' "$counts" | awk '{print $1}')
  METRIC_COMMENT=$(printf '%s' "$counts" | awk '{print $2}')

  METRIC_FILES=$(printf '%s' "$prod" | sed '/^$/d' | wc -l | tr -d ' ')

  local tcounts=0
  if [ -n "$(printf '%s' "$test_files" | sed '/^$/d')" ]; then
    tcounts=$(cd "$REPO" && printf '%s' "$test_files" | sed '/^$/d' | tr '\n' '\0' \
              | xargs -0 -r awk "$COUNT_AWK" 2>/dev/null \
              | awk '{ c += $1 } END { printf "%d\n", c + 0 }')
  fi
  METRIC_TESTLINES=${tcounts:-0}

  # Escape hatches: the spellings that turn a checker off. Counted together
  # because what matters is that the total is climbing, not which one it was.
  METRIC_ESCAPES=$(cd "$REPO" && printf '%s' "$prod" | sed '/^$/d' | tr '\n' '\0' \
    | xargs -0 -r grep -ohE 'as any|@ts-ignore|@ts-nocheck|eslint-disable|# *type: *ignore|# *noqa|#\[allow\(' 2>/dev/null \
    | wc -l | tr -d ' ')

  METRIC_BIG=0
  METRIC_MAX=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local n
    n=$(wc -l < "$REPO/$f" 2>/dev/null | tr -d ' ') || continue
    [ -n "$n" ] || continue
    [ "$n" -gt "$BIG_FILE_LINES" ] && METRIC_BIG=$(( METRIC_BIG + 1 ))
    [ "$n" -gt "$METRIC_MAX" ] && METRIC_MAX=$n
  done <<EOF
$(printf '%s' "$prod" | sed '/^$/d')
EOF
}

# Comment share of the non-test source lines ADDED since $1. This is the leading
# indicator: it reads the code being written now, not the average of everything
# ever written.
measure_window() { # $1 = previous sha ("-" when there is none)
  METRIC_NEWCODE=0
  METRIC_NEWCOMMENT=0
  local prev=$1
  [ "$prev" != "-" ] || return 0
  git_r merge-base --is-ancestor "$prev" HEAD 2>/dev/null || return 0

  local out
  out=$(git_r diff --unified=0 "$prev"..HEAD 2>/dev/null | awk "$DIFF_AWK") || return 0
  METRIC_NEWCODE=$(printf '%s' "$out" | awk '{print $1}')
  METRIC_NEWCOMMENT=$(printf '%s' "$out" | awk '{print $2}')
}

# --- history -----------------------------------------------------------------

HEADER=$'date\tsha\tfiles\tcode\tcmt%\tnew_cmt%\tescapes\tbig\tmax\ttest%\tnote'

last_sha() { # last recorded sha, or "-"
  local file=$1
  [ -f "$file" ] || { printf '%s' '-'; return; }
  awk -F'\t' 'NR > 1 && NF >= 2 { s = $2 } END { print (s == "" ? "-" : s) }' "$file"
}

print_delta() { # $1 = metrics file
  local file=$1
  [ -f "$file" ] || return 0
  local rows
  rows=$(awk 'NR > 1' "$file" | wc -l | tr -d ' ')
  if [ "$rows" -lt 2 ]; then
    echo "first recorded pass - no delta yet; the next pass compares against this one."
    return 0
  fi
  awk -F'\t' '
    NR > 1 { prev2 = prev; prev = $0 }
    END {
      split(prev2, a, "\t"); split(prev, b, "\t")
      printf "delta since %s (%s -> %s)\n", a[1], substr(a[2], 1, 8), substr(b[2], 1, 8)
      names["3"] = "files"; names["4"] = "code lines"; names["5"] = "comment %"
      names["6"] = "new-code comment %"; names["7"] = "escape hatches"
      names["8"] = "files > threshold"; names["9"] = "largest file"; names["10"] = "test %"
      for (i = 3; i <= 10; i++) {
        if (a[i] == "-" || b[i] == "-") { printf "  %-20s %8s -> %-8s\n", names[i], a[i], b[i]; continue }
        d = b[i] - a[i]
        sign = (d > 0) ? "+" : ""
        printf "  %-20s %8s -> %-8s  %s%s\n", names[i], a[i], b[i], sign, (d == int(d) ? int(d) : sprintf("%.1f", d))
      }
    }
  ' "$file"
}

# --- commands ----------------------------------------------------------------

cmd_record() {
  local note=""
  shift 1 || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --note) note=${2:-}; shift 2 ;;
      *) die "record: unknown option '$1'" ;;
    esac
  done

  local file prev
  file=$(metrics_file "$PROJECT")
  prev=$(last_sha "$file")

  measure
  measure_window "$prev"

  local total=$(( METRIC_CODE + METRIC_COMMENT ))
  local newtotal=$(( METRIC_NEWCODE + METRIC_NEWCOMMENT ))
  local sha date row
  sha=$(git_r rev-parse HEAD)
  date=$(date -u +%Y-%m-%d)
  # A tab or newline in the note would break the row apart.
  note=$(printf '%s' "$note" | tr '\t\n' '  ')

  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || printf '%s\n' "$HEADER" > "$file"
  row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$date" "$sha" "$METRIC_FILES" "$METRIC_CODE" \
    "$(pct "$METRIC_COMMENT" "$total")" \
    "$(pct "$METRIC_NEWCOMMENT" "$newtotal")" \
    "$METRIC_ESCAPES" "$METRIC_BIG" "$METRIC_MAX" \
    "$(pct "$METRIC_TESTLINES" "$METRIC_CODE")" \
    "$note")
  printf '%s\n' "$row" >> "$file"

  echo "recorded $PROJECT at $(printf '%s' "$sha" | cut -c1-8) -> $file"
  print_delta "$file"
}

cmd_show() {
  local file
  file=$(metrics_file "$PROJECT")
  [ -f "$file" ] || { echo "no metrics recorded for $PROJECT yet"; return 0; }
  column -t -s"$(printf '\t')" < "$file" 2>/dev/null || cat "$file"
}

cmd_delta() {
  local file
  file=$(metrics_file "$PROJECT")
  [ -f "$file" ] || { echo "no metrics recorded for $PROJECT yet"; return 0; }
  print_delta "$file"
}

# --- entry -------------------------------------------------------------------

[ $# -ge 1 ] || { usage; exit 2; }
CMD=$1
case "$CMD" in
  -h|--help|help) usage; exit 0 ;;
esac
[ $# -ge 2 ] || die "$CMD needs a project name"
PROJECT=$2
REPO=$(repo_dir "$PROJECT")
[ -d "$REPO/.git" ] || git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || die "no git repo at $REPO"

shift 1
case "$CMD" in
  record) cmd_record "$@" ;;
  show)   cmd_show ;;
  delta)  cmd_delta ;;
  *)      die "unknown command '$CMD' (expected record, show or delta)" ;;
esac
