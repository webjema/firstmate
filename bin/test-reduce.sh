#!/usr/bin/env bash
# The file-level review ledger that drives a test-reduction campaign: it lets a
# large test corpus be processed in bounded, disjoint packs, tracked, and resumed
# instead of reviewed all at once.
#
# It is modelled on bin/fm-review-ledger.sh but slices at FILE granularity, not
# directory granularity. That engine's own header records why: its directory-level
# selection mis-handles a project with a few huge directories - it covered the
# twelve smallest units and none of the four biggest. A test corpus is exactly
# that shape (its unit is a top-level tracked directory, and optiroq's `src` holds
# 669 of its 861 test files), so a whole directory is too coarse a unit to hand a
# crew. One test file is the unit here.
# Ledgers live at data/reviews/<project>/test-reduce.md under the active firstmate
# home, one row per test file. They are firstmate-private (data/ is gitignored),
# because what firstmate has processed for the user is the user's operational
# record, not the project's. The tool only reads the clone's file list and writes
# this ledger; it never mutates the target project.
# A row carries the file, its status (pending, in-review, done), the commit it was
# recorded at, the date, the counts of tests removed and duplicates merged in that
# pass, an optional PR url, and a one-line outcome. A done file is re-opened for
# review when it is edited after its pass: selection is git-based against the
# recorded commit (a commit touching the file since then, or an uncommitted edit,
# re-opens it) and falls back to the recorded date after a history rewrite, so a
# rebase degrades selection instead of breaking it.
# Usage: test-reduce.sh init <project>
#              Seed the ledger with every test file in the project's clone
#              (*.test.ts, *.test.tsx, *.spec.ts; node_modules excluded) as
#              pending. Idempotent: re-running adds newly-created test files
#              without disturbing existing rows.
#        test-reduce.sh next-pack <project> [--size N]
#              Select the next disjoint pack of pending files, mark them
#              in-review, and print the file list (one path per line) for a crew
#              brief. Packs are disjoint by construction (a picked file is marked
#              in-review and never re-picked), so the packs run as parallel crews.
#              The next-pack calls that produce them are issued serially by
#              firstmate (one orchestrator thread); the read-modify-write here is
#              not lock-guarded and must not be run concurrently against one ledger.
#              Prints NOTHING_TO_REVIEW and exits 0 when the corpus is drained.
#              Default pack size is 10 (FM_TEST_REDUCE_PACK_SIZE, or --size N).
#              Prioritisation (FM_TEST_REDUCE_ORDER) defaults to `count`: the
#              directories holding the most pending files first, so the biggest
#              duplication clusters are tackled first; `path` orders lexically.
#        test-reduce.sh record <project> <file> --outcome <text> [--sha <sha>]
#                              [--removed N] [--merged N] [--pr <url>]
#              Mark <file> done at its current commit (or --sha) with a one-line
#              outcome and the tests-removed / duplicates-merged counts. Replaces
#              any prior row for that file; the file stays sorted for stable diffs.
#        test-reduce.sh status <project>
#              Coverage overview: files done / total, tests removed, duplicates
#              merged, pending / in-review / re-opened counts, plus any ledger row
#              whose file no longer exists (ORPHAN).
set -eu

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

DEFAULT_PACK_SIZE=${FM_TEST_REDUCE_PACK_SIZE:-10}
ORDER=${FM_TEST_REDUCE_ORDER:-count}
TAB=$(printf '\t')

# The test-file globs. Git pathspecs, so `*` spans directory separators and each
# matches a file at any depth.
TEST_GLOBS=('*.test.ts' '*.test.tsx' '*.spec.ts')

die() { echo "error: $*" >&2; exit 1; }

# --- paths ------------------------------------------------------------------

ledger_file() { printf '%s\n' "$DATA/reviews/$1/test-reduce.md"; }
repo_dir() { printf '%s\n' "$PROJECTS/$1"; }

assert_repo() {
  local repo=$1
  [ -d "$repo/.git" ] || git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || die "no git repo at $repo"
}

# core.quotePath=false so a path with non-ASCII bytes comes back verbatim, not
# C-quoted - a quoted path would be stored, then never match itself as a pathspec.
git_r() { git -C "$REPO" -c core.quotePath=false "$@"; }

# --- test-file discovery ----------------------------------------------------

# Every test file in the clone: tracked plus untracked-but-not-ignored (a new
# test a crew added is a candidate before it is committed), node_modules excluded.
# --exclude-standard already drops an ignored node_modules; the grep guards the
# rare tracked one.
list_test_files() {
  {
    git_r ls-files -- "${TEST_GLOBS[@]}"
    git_r ls-files --others --exclude-standard -- "${TEST_GLOBS[@]}"
  } 2>/dev/null | grep -Ev '(^|/)node_modules/' | sort -u
}

# --- ledger read/write ------------------------------------------------------

# Emit data rows as file<TAB>status<TAB>sha<TAB>date<TAB>removed<TAB>merged<TAB>pr<TAB>outcome.
# Tolerates a missing file.
ledger_rows() {
  local f=$1
  [ -f "$f" ] || return 0
  awk -F'|' '
    /^\| *file *\|/ { next }
    /^\| *:?-+ *\|/ { next }
    /^\|/ {
      for (i = 2; i <= 9; i++) { gsub(/^ +| +$/, "", $i) }
      print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9
    }
  ' "$f"
}

# Write the whole ledger from TAB rows on stdin, sorted by file for stable diffs.
ledger_write_all() {
  local f=$1 dir tmp
  dir=$(dirname "$f")
  mkdir -p "$dir"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-test-reduce.XXXXXX") || die "mktemp failed"
  sort -t"$TAB" -k1,1 > "$tmp.rows"
  {
    printf '# %s - test-reduction ledger\n' "$PROJECT"
    printf '# Managed by bin/test-reduce.sh. One row per test file.\n\n'
    printf '| file | status | sha | date | removed | merged | pr | outcome |\n'
    printf '| --- | --- | --- | --- | --- | --- | --- | --- |\n'
    awk -F'\t' '{ printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n", \
      $1, $2, $3, $4, $5, $6, $7, $8 }' "$tmp.rows"
  } > "$tmp"
  mv -f "$tmp" "$f"
  rm -f "$tmp.rows"
}

# Sanitize a free-text field to one line with no field delimiter.
clean_field() { printf '%s' "$1" | tr '\n' ' ' | tr '|' '/'; }

# Replace (or add) the row for <file>.
ledger_upsert() {
  local file=$1 status=$2 sha=$3 date=$4 removed=$5 merged=$6 pr=$7 outcome=$8
  pr=$(clean_field "$pr")
  outcome=$(clean_field "$outcome")
  {
    ledger_rows "$LEDGER" | awk -F'\t' -v k="$file" '$1 != k'
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$file" "$status" "$sha" "$date" "$removed" "$merged" "$pr" "$outcome"
  } | ledger_write_all "$LEDGER"
}

# --- staleness --------------------------------------------------------------
#
# Whether a done file has moved since its pass is a git question. Asked per file
# it is three git plumbing calls each, and at file granularity a drained corpus is
# hundreds of files - thousands of subprocesses per next-pack/status. So it is
# asked in BATCH instead: one whole-tree dirty set, and one "changed since X" set
# per DISTINCT recorded commit (memoised), because rows recorded together share a
# commit. Membership is then a cheap fixed-string lookup, not a git call.

CHANGED_CACHE=""

# Build the cache dir and the whole-tree dirty set once per process. The dirty set
# is every path with a staged, unstaged, or untracked change; a rename's 3-char
# status prefix and "old -> new" form both reduce to the new path.
init_changed_cache() {
  [ -n "$CHANGED_CACHE" ] && return 0
  CHANGED_CACHE=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-reduce-cache.XXXXXX") || die "mktemp failed"
  trap 'rm -rf "$CHANGED_CACHE"' EXIT
  git_r status --porcelain 2>/dev/null \
    | sed -e 's/^...//' -e 's/.* -> //' | sort -u > "$CHANGED_CACHE/dirty"
}

# Classify every ledger row's EFFECTIVE status in one pass, emitting
# file<TAB>stored_status<TAB>effective_status. A done file that has moved since its
# pass re-opens (effective pending); every other status is its stored value. The
# git cost is bounded to one dirty read plus one "changed since" read per DISTINCT
# recorded (sha, date), never per row, so a drained 800-file corpus stays a handful
# of git calls and one awk, not thousands of subprocesses. An uncommitted edit
# counts as a change; a rewrite that orphans a sha falls back to the recorded date.
classify_all() {
  init_changed_cache
  local rows memb keys sha date setf
  rows=$(mktemp "${TMPDIR:-/tmp}/fm-test-reduce-rows.XXXXXX") || die "mktemp failed"
  memb=$(mktemp "${TMPDIR:-/tmp}/fm-test-reduce-memb.XXXXXX") || die "mktemp failed"
  setf=$(mktemp "${TMPDIR:-/tmp}/fm-test-reduce-set.XXXXXX") || die "mktemp failed"
  ledger_rows "$LEDGER" > "$rows"

  # A sentinel first line so the two-file awk's FNR==NR test is reliable even when
  # there are no dirty files and no done rows (an empty first file makes awk read
  # the SECOND file's first record with NR==FNR, misclassifying every row).
  printf '!INIT!\t\n' > "$memb"
  # dirty membership, under a reserved key no (sha,date) can collide with.
  awk '{ print "!DIRTY!\t" $0 }' "$CHANGED_CACHE/dirty" >> "$memb"

  # one "changed since" set per distinct (sha, date) of the done rows. A sha and a
  # date never contain a tab, so sha<TAB>date is an unambiguous key.
  keys=$(awk -F'\t' '$2 == "done" { print $3 "\t" $4 }' "$rows" | sort -u)
  if [ -n "$keys" ]; then
    while IFS="$TAB" read -r sha date; do
      if [ -n "$sha" ] && git_r merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        git_r diff --name-only "$sha" HEAD 2>/dev/null > "$setf" || : > "$setf"
      else
        git_r log --since="$date" --name-only --pretty=format: 2>/dev/null | sort -u > "$setf" || : > "$setf"
      fi
      awk -v k="$sha	$date" '{ print k "\t" $0 }' "$setf" >> "$memb"
    done <<EOF
$keys
EOF
  fi

  awk -F'\t' -v OFS='\t' '
    FNR == NR {
      if ($1 == "!INIT!") { next }
      if ($1 == "!DIRTY!") { dirty[$2] = 1 }
      else { changed[$1 SUBSEP $2 SUBSEP $3] = 1 }
      next
    }
    {
      file = $1; status = $2; sha = $3; date = $4
      if (status == "done" && ((file in dirty) || (sha SUBSEP date SUBSEP file) in changed)) {
        print file, status, "pending"
      } else {
        print file, status, status
      }
    }
  ' "$memb" "$rows"

  rm -f "$rows" "$memb" "$setf"
}

# --- init -------------------------------------------------------------------

cmd_init() {
  local total=0 added=0 file rows_tmp new_tmp
  rows_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-test-reduce-rows.XXXXXX") || die "mktemp failed"
  new_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-test-reduce-new.XXXXXX") || die "mktemp failed"
  ledger_rows "$LEDGER" > "$rows_tmp"

  local -A have=()
  while IFS="$TAB" read -r file _; do
    [ -n "$file" ] && have["$file"]=1
  done < "$rows_tmp"

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    total=$(( total + 1 ))
    [ -n "${have["$file"]:-}" ] && continue
    printf '%s\t%s\t\t\t0\t0\t\t\n' "$file" pending >> "$new_tmp"
    added=$(( added + 1 ))
  done < <(list_test_files)

  cat "$rows_tmp" "$new_tmp" | ledger_write_all "$LEDGER"
  rm -f "$rows_tmp" "$new_tmp"
  echo "init: $total test file(s) present in $PROJECT, $added new row(s) added ($(( total - added )) already tracked)"
}

# --- next-pack --------------------------------------------------------------

# Order candidate files on stdin per ORDER, one per line.
order_candidates() {
  case "$ORDER" in
    path) sort ;;
    count|*)
      # Tag each file with the number of candidates sharing its directory, then
      # sort by that count desc so the biggest duplication clusters come first;
      # ties break by directory then file for a deterministic order.
      awk '
        { f[NR] = $0; d = $0; if (sub(/\/[^/]*$/, "", d) == 0) d = "."; dir[NR] = d; cnt[d]++ }
        END { for (i = 1; i <= NR; i++) printf "%d\t%s\t%s\n", cnt[dir[i]], dir[i], f[i] }
      ' | sort -t"$TAB" -k1,1nr -k2,2 -k3,3 | cut -f3-
      ;;
  esac
}

cmd_next_pack() {
  local size=$DEFAULT_PACK_SIZE
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --size) size=${2:-}; shift 2 ;;
      *) die "next-pack: unknown option '$1'" ;;
    esac
  done
  case "$size" in
    ''|*[!0-9]*) die "next-pack: --size must be a positive integer" ;;
  esac
  [ "$size" -ge 1 ] || die "next-pack: --size must be at least 1"

  local cand_tmp
  cand_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-test-reduce-cand.XXXXXX") || die "mktemp failed"
  classify_all | awk -F'\t' '$3 == "pending" { print $1 }' \
    | order_candidates | head -n "$size" > "$cand_tmp"

  if [ ! -s "$cand_tmp" ]; then
    rm -f "$cand_tmp"
    echo "NOTHING_TO_REVIEW"
    return 0
  fi

  # Mark the chosen files in-review, then print them.
  {
    ledger_rows "$LEDGER" | awk -F'\t' -v OFS='\t' -v listfile="$cand_tmp" '
      BEGIN { while ((getline l < listfile) > 0) pick[l] = 1 }
      { if ($1 in pick) $2 = "in-review"; print }
    '
  } | ledger_write_all "$LEDGER"

  cat "$cand_tmp"
  rm -f "$cand_tmp"
}

# --- record -----------------------------------------------------------------

cmd_record() {
  local file=${1:-} sha="" outcome="" removed=0 merged=0 pr=""
  shift || true
  [ -n "$file" ] || die "record needs a file"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --outcome) outcome=${2:-}; shift 2 ;;
      --sha) sha=${2:-}; shift 2 ;;
      --removed) removed=${2:-}; shift 2 ;;
      --merged) merged=${2:-}; shift 2 ;;
      --pr) pr=${2:-}; shift 2 ;;
      *) die "record: unknown option '$1'" ;;
    esac
  done
  [ -n "$outcome" ] || die "record needs --outcome"
  case "$removed" in ''|*[!0-9]*) die "record: --removed must be a non-negative integer" ;; esac
  case "$merged" in ''|*[!0-9]*) die "record: --merged must be a non-negative integer" ;; esac
  [ -n "$sha" ] || sha=$(git_r rev-parse HEAD)
  local date=${FM_LEDGER_DATE:-$(date +%F)}
  ledger_upsert "$file" "done" "$sha" "$date" "$removed" "$merged" "$pr" "$outcome"
  echo "recorded: $file done at ${sha:0:8} ($date) - removed $removed, merged $merged - $outcome"
}

# --- status -----------------------------------------------------------------

cmd_status() {
  local total done_ct=0 pending=0 inreview=0 reopened=0 removed_sum=0 merged_sum=0
  local file status eff removed merged orphans=""
  local -A present=()
  while IFS= read -r file; do
    [ -n "$file" ] && present["$file"]=1
  done < <(list_test_files)
  total=${#present[@]}

  # Counts by effective status, skipping orphans (a gone file is neither done nor
  # pending, it is flagged separately below).
  while IFS="$TAB" read -r file status eff; do
    [ -n "$file" ] || continue
    [ -n "${present["$file"]:-}" ] || continue
    case "$eff" in
      done)      done_ct=$(( done_ct + 1 )) ;;
      in-review) inreview=$(( inreview + 1 )) ;;
      pending)
        if [ "$status" = "done" ]; then reopened=$(( reopened + 1 )); else pending=$(( pending + 1 )); fi
        ;;
    esac
  done < <(classify_all)

  # removed/merged sums and ORPHAN flags come straight from the stored rows (no git).
  while IFS="$TAB" read -r file _ _ _ removed merged _; do
    [ -n "$file" ] || continue
    removed_sum=$(( removed_sum + ${removed:-0} ))
    merged_sum=$(( merged_sum + ${merged:-0} ))
    [ -n "${present["$file"]:-}" ] || orphans="$orphans  $file  ORPHAN (file no longer present)"$'\n'
  done < <(ledger_rows "$LEDGER")

  [ -n "$orphans" ] && printf '%s' "$orphans"
  printf 'coverage: %s/%s test files done (%s tests removed, %s duplicates merged)\n' \
    "$done_ct" "$total" "$removed_sum" "$merged_sum"
  printf 'in progress: %s pending, %s in-review, %s re-opened (edited after a pass)\n' \
    "$pending" "$inreview" "$reopened"
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac

ACTION=$1
shift || true

[ "$#" -ge 1 ] || die "$ACTION needs a project"
PROJECT=$1
shift
REPO=$(repo_dir "$PROJECT")
assert_repo "$REPO"
LEDGER=$(ledger_file "$PROJECT")

case "$ACTION" in
  init)      cmd_init ;;
  next-pack) cmd_next_pack "$@" ;;
  record)    cmd_record "$@" ;;
  status)    cmd_status ;;
  *) die "unknown action '$ACTION' (see --help)" ;;
esac
