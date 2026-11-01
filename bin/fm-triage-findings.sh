#!/usr/bin/env bash
# Drain the fleet finding queue: the mechanical half of triage. bin/fm-file-finding.sh files
# a fleet finding under a machine-drainable `verify` hold (bin/fm-finding-lib.sh owns that
# hold contract); this script LISTS those holds for a verifier and APPLIES the verifier's
# verdict, and MIGRATEs the pre-flip queue onto the verify hold. It makes NO code judgment -
# it never opens the file a finding points at. The `triage` skill is the judgment half: it
# reads each finding in the current code and decides the verdict this script then applies.
# AGENTS.md section 5 owns the RULE (verify-then-dispatch, and which findings still reach a
# human); this header owns the MECHANICS.
#
# Usage:
#   fm-triage-findings.sh list [--limit N] [--file <backlog.md> | --asana [--repo <owner/repo>]]
#   fm-triage-findings.sh apply <id> --verdict <real|fixed|obsolete|duplicate|decision>
#                                 --evidence <text> [--question <text>] [--duplicate-of <id>]
#                                 [--file <backlog.md> | --asana [--repo <owner/repo>]]
#   fm-triage-findings.sh migrate [--file <backlog.md>]
#
# --asana drains the product board's Triage section instead of the fleet backlog (see ASANA
# below). --repo picks the board the way bin/fm-file-finding.sh does for a finding about that
# repository; without it the default board is drained.
#
# --file points every verb at a specific backlog file instead of $FM_HOME/data/backlog.md, so
# the drain can be exercised against a copy without touching the live queue. tasks-axi carries
# it through to the row it edits.
#
# LIST emits one JSON object per line (JSONL), oldest hold first, capped at --limit (default
# 8) so a verifier gets a bounded batch rather than the whole queue. Only verify holds are
# listed: a captain hold (a real decision/resource question) and any other tool's `parked`
# hold are skipped, so the drain never dispatches a finding a human is meant to answer. Each
# record carries id, title, repo, where (the file:line the finding names), why, expected,
# hold_reason, created, and age_days - enough for the verifier to find the code without this
# script reading it. where/why/expected are parsed from the finding body, which follows the
# bug-report shape bin/fm-file-finding.sh writes; a finding missing a field just carries "".
#
# APPLY records one verdict for one finding, idempotently, and NEVER drops a finding: every
# path either resolves the hold or leaves it exactly as it was. --evidence is required and is
# recorded so a closed or dispatched finding says why.
#   real      the defect still reproduces in current code. The hold is cleared and the finding
#             becomes dispatchable work - UNLESS the safety floor (below) fires, in which case
#             it escalates to the captain instead, whatever the verdict.
#   fixed     the code already fixes it. The finding is closed with the evidence as its note.
#   obsolete  the finding no longer applies (code deleted, design changed). Closed likewise.
#   duplicate the finding repeats another one, named by --duplicate-of. Closed likewise, with
#             "duplicate of <id>" leading the note.
#   decision  verifying it surfaced a product/architecture call only the captain can make.
#             Re-held under kind captain with --question as the reason; --question is REQUIRED,
#             like it is at filing time, because a captain hold with no question is a silent
#             row. This is the drain's own escalation path.
# Idempotence is by current state, read before acting: a `real` finding already unheld, a
# `fixed`/`obsolete` finding already closed, or a `decision` finding already on the same
# captain hold is reported as already-applied and the tracker is not touched again. A finding
# whose hold is no longer a verify hold is refused (it was already triaged or was never in the
# queue), so a stale batch cannot re-open a resolved finding. Any tasks-axi failure leaves the
# finding on its verify hold and exits non-zero, so a failed apply loses nothing.
#
# THE SAFETY FLOOR. The drain must never auto-dispatch something destructive, irreversible, or
# security-sensitive, however confidently a verifier calls it real: those are exactly the
# things AGENTS.md section 8 keeps escalating to a human. So `apply --verdict real` scans the
# finding's own text (title + where + why + expected) for danger markers - privilege and root,
# secret and credential handling, history rewriting and force pushes, data deletion,
# production deploys, anything self-described as destructive or irreversible - and on a match
# it escalates to the captain (kind captain, a reason naming the marker) INSTEAD of clearing
# the hold. The verdict is still real; the floor only refuses to let the machine be the one to
# start the work. The scan is deliberately broad: a false escalation costs one captain glance,
# a false dispatch could run the dangerous change unattended, and those are not equal.
#
# ASANA. With --asana, the queue is the open cards in the board's Triage section (the section
# gid bin/fm-file-finding.sh files into), and the id is a card gid. LIST emits the same
# record shape, plus severity (from the sev:S# tag) and url; hold_reason is absent, because
# every card in Triage is waiting for this drain. APPLY uses the same verdicts, gates and
# safety floor, with board moves in place of holds. It comments the verdict on the card, then:
#   fixed, obsolete   completes the card.
#   duplicate         first comments the card's text on the --duplicate-of card, then
#                     completes it, so the open card carries all the evidence.
#   real              moves the card to the queue section (queue-section=, default "Agent
#                     queue"), where the pipeline picks work up. A danger marker moves it to
#                     the captain section (captain-section=, default "Needs captain") instead.
#   decision          moves the card to the captain section, with --question in the comment.
# The sections are found by name on the card's board (config/product-tracker owns the names).
# A card not on the board is refused. A card not in Triage is refused, except when it is
# already where this verdict puts it, which is reported as already-applied. A board with no
# section of the needed name, or a failed Asana call, leaves the card in Triage and exits 1.
# The comment goes first, so a retry after a failed move only adds a second comment.
#
# MIGRATE is the one-time flip for a queue filed before the default inverted: every task held
# under kind captain with the exact generic reason "unreviewed finding - triage before
# dispatching" is re-held under the verify hold, so the standing backlog drains like a freshly
# filed one. It matches that reason EXACTLY, so a real captain question - which reads as an
# actual decision, never that placeholder - is left on its captain hold. It is idempotent:
# a second run finds nothing left carrying the generic reason.
#
# Exit status: 0 on success (including an idempotent no-op and an escalation); 2 for a usage
# error; 1 when a tracker call failed and the finding was left held.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fm_tasks_axi_backend_available (the one owner of "may this home use tasks-axi").
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# The verify-hold contract shared with bin/fm-file-finding.sh.
# shellcheck source=bin/fm-finding-lib.sh
. "$SCRIPT_DIR/fm-finding-lib.sh"

# The exact reason a pre-flip queue was held under. Matched whole by migrate, so it is a
# literal here on purpose - it names the placeholder the old filer wrote, not a live contract.
GENERIC_HOLD_REASON="unreviewed finding - triage before dispatching"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { echo "fm-triage-findings.sh: $1" >&2; exit 2; }

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

command -v jq >/dev/null 2>&1 || die "jq is required"

VERB="${1:-}"
[ -n "$VERB" ] || { usage; exit 2; }
case "$VERB" in
  -h|--help) usage; exit 0 ;;
esac
shift || true

# Every verb shares --file, --asana and --repo; parse them out first, leaving the rest.
BACKLOG=""
ASANA=0
REPO=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --file) [ $# -ge 2 ] || die "--file needs a value"; BACKLOG=$2; shift 2 ;;
    --asana) ASANA=1; shift ;;
    --repo) [ $# -ge 2 ] || die "--repo needs a value"; REPO=$2; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ -n "$BACKLOG" ] || BACKLOG="$DATA/backlog.md"
[ "$ASANA" -eq 1 ] || [ -z "$REPO" ] || die "--repo only picks a board, so it needs --asana"
[ "$ASANA" -eq 0 ] || [ "$VERB" != migrate ] || die "migrate is backlog-only"

if [ "$ASANA" -eq 1 ]; then
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-triage.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
  # shellcheck source=bin/fm-asana-lib.sh
  . "$SCRIPT_DIR/fm-asana-lib.sh"
  asana_target_for "$REPO" || die "$API_ERR"
  [ -n "$ASANA_PROJECT" ] || die "no product tracker configured (config/product-tracker project=)"
  [ -n "$ASANA_SECTION" ] || die "no triage section configured for board $ASANA_PROJECT; there is nothing to drain"
  asana_ready || die "$API_ERR"
else
  # tasks-axi, always pointed at the chosen backlog file. The backlog drain needs the
  # backend; when it is opted out or too old there is nothing to drain through and that is a
  # hard error, not a silent skip.
  fm_tasks_axi_backend_available "$CONFIG" ||
    die "tasks-axi backend unavailable (absent, too old, or config/backlog-backend=manual); the drain needs it"
fi
axi() { tasks-axi "$@" --file "$BACKLOG"; }

# --- shared reads ------------------------------------------------------------
# Every held task as `id<TAB>hold_kind<TAB>hold_reason<TAB>created`, one per line. Parsed from
# `list`, whose row order is file order (the queue order). The per-finding detail comes from
# `show` instead; this read is only for the hold triage.
#
# INVARIANT this parse depends on: the row is `id, hold_kind, hold_reason, created` and awk
# splits on EVERY comma - including any inside a quoted value, since a plain -F',' does not
# honour CSV quoting. Reading id from the left and created/reason/kind from the right is only
# unambiguous while the three right-hand columns are comma-free, which holds for every hold
# this drain acts on: the fixed verify reason and the exact generic reason are both comma-free
# constants, and `created` is a comma-free date. A comma in one of those, or a new column added
# after `created`, would shift the right-anchored read - so do not introduce either. A comma in
# some OTHER hold's reason (e.g. a free-text captain question) only mis-splits that row's kind
# and reason into fragments, and a fragment is never both kind `parked` and a `verify:` reason,
# so a foreign hold can never be mis-read AS a verify hold - the triage decision stays safe.
held_rows() {
  axi list --state held --fields hold_kind,hold_reason,created 2>/dev/null |
    awk -F',' '
      /^  [a-z0-9]/ {
        line = $0
        sub(/^  /, "", line)
        n = split(line, f, ",")
        id = f[1]
        created = f[n]
        reason = f[n-1]
        kind = f[n-2]
        gsub(/^ +| +$/, "", id); gsub(/^ +| +$/, "", kind)
        gsub(/^ +| +$/, "", reason); gsub(/^ +| +$/, "", created)
        # tasks-axi wraps a comma-free-but-quoted value (a dash-only placeholder) in double
        # quotes; strip one symmetric pair. This does NOT rescue a comma-bearing value - see
        # the invariant above for why that never reaches a column we depend on.
        gsub(/^"|"$/, "", reason); gsub(/^"|"$/, "", created)
        printf "%s\t%s\t%s\t%s\n", id, kind, reason, created
      }'
}

# The full body text of a finding, `\n`-unescaped, on stdout. tasks-axi show renders the body
# as one physical `  body: "..."` line with C-style escapes; awk unescapes portably (BSD sed
# does not read \n in a replacement, so sed is avoided here).
show_body() {  # <id>
  axi show "$1" --full 2>/dev/null |
    awk '
      /^  body: / {
        line = $0
        sub(/^  body: /, "", line)
        sub(/^"/, "", line); sub(/"$/, "", line)
        gsub(/\\n/, "\n", line)
        gsub(/\\t/, "\t", line)
        gsub(/\\"/, "\"", line)
        print line
        exit
      }'
}

show_scalar() {  # <id> <field>
  axi show "$1" --full 2>/dev/null |
    awk -v f="  $2: " 'index($0, f) == 1 { v = substr($0, length(f) + 1); sub(/^"/, "", v); sub(/"$/, "", v); if (v == "-") v = ""; print v; exit }'
}

# --- list --------------------------------------------------------------------
do_list() {
  local limit=8
  local -a rest=()
  local i
  for ((i = 0; i < ${#ARGS[@]}; i++)); do
    case "${ARGS[i]}" in
      --limit) limit=${ARGS[i+1]:-}; i=$((i+1)) ;;
      *) rest+=("${ARGS[i]}") ;;
    esac
  done
  [ ${#rest[@]} -eq 0 ] || die "list: unexpected argument '${rest[0]}'"
  case "$limit" in
    ''|*[!0-9]*) die "list: --limit needs a number, got '$limit'" ;;
  esac

  local today emitted=0 id kind reason created
  today=$(date -u +%s)
  if [ "$ASANA" -eq 1 ]; then
    asana_list "$limit" "$today"
    return
  fi
  while IFS=$'\t' read -r id kind reason created; do
    [ -n "$id" ] || continue
    fm_is_verify_hold "$kind" "$reason" || continue
    [ "$emitted" -lt "$limit" ] || break
    emit_list_record "$id" "$reason" "$created" "$today"
    emitted=$((emitted + 1))
  done < <(held_rows)
  # A silent empty batch is a valid answer - the queue is drained - but say so on stderr so a
  # human running it by hand is not left wondering whether it worked.
  [ "$emitted" -gt 0 ] || echo "list: no findings are awaiting triage" >&2
}

emit_list_record() {  # <id> <hold-reason> <created> <today-epoch>
  local id=$1 reason=$2 created=$3 today=$4 body title repo where expected why age=""
  body=$(show_body "$id")
  title=$(show_scalar "$id" title)
  repo=$(show_scalar "$id" repo)
  where=$(printf '%s\n' "$body" | sed -n 's/^Where: *//p' | head -1)
  expected=$(printf '%s\n' "$body" | sed -n 's/^Expected\( instead\)\?: *//p' | head -1)
  # why is the finding's own account of the defect: the body up to the Where line, with a
  # leading `Issue` header (the current template's) dropped, collapsed and capped so the batch
  # record stays scannable. The verifier re-reads the code for the truth of it.
  why=$(printf '%s\n' "$body" |
    awk 'BEGIN{p=1} /^Where: /{p=0} p{print}' |
    awk 'NR==1 && $0=="Issue"{next} {print}' |
    tr '\n' ' ' | tr -s ' ' | sed 's/^ //; s/ $//' | cut -c1-280)
  if [ -n "$created" ]; then
    local c
    if c=$(date -u -d "$created" +%s 2>/dev/null) || c=$(date -u -j -f %Y-%m-%d "$created" +%s 2>/dev/null); then
      age=$(( (today - c) / 86400 ))
    fi
  fi
  jq -cn \
    --arg id "$id" --arg title "$title" --arg repo "$repo" --arg where "$where" \
    --arg why "$why" --arg expected "$expected" --arg reason "$reason" \
    --arg created "$created" --arg age "$age" \
    '{id:$id,title:$title,repo:$repo,where:$where,why:$why,expected:$expected,
      hold_reason:$reason,created:$created,age_days:($age|if .=="" then null else tonumber end)}'
}

# --- apply -------------------------------------------------------------------
# The danger markers the safety floor escalates on, whatever the verdict. Case-insensitive,
# matched against the finding's own text. Deliberately broad: a false escalation is one glance,
# a false auto-dispatch could run the change unattended.
DANGER_RE='rm +-[rf]|force[ -]?push|--force|reset +--hard|filter-branch|history rewrite|drop +(table|database)|delete +from|truncate|mkfs|dd +if=|shred|/dev/sd|terraform +destroy|kubectl +delete|credential|secret|password|private key|ssh key|access token|api[ -]?key|sudo|setuid|/etc/|systemd|privilege escalat|chmod +[0-7]|chown |production deploy|deploy +to +prod|irreversible|destructive|data loss'

danger_marker() {  # <text>  -> prints the matched marker, or nothing
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | grep -oiE "$DANGER_RE" | head -1 || true
}

do_apply() {
  local id="" verdict="" evidence="" question="" dup="" i
  [ ${#ARGS[@]} -gt 0 ] || die "apply needs a finding id (see --help)"
  id=${ARGS[0]}
  case "$id" in --*) die "apply needs a finding id as its first argument (see --help)" ;; esac
  for ((i = 1; i < ${#ARGS[@]}; i++)); do
    case "${ARGS[i]}" in
      --verdict)  verdict=${ARGS[i+1]:-}; i=$((i+1)) ;;
      --evidence) evidence=${ARGS[i+1]:-}; i=$((i+1)) ;;
      --question) question=${ARGS[i+1]:-}; i=$((i+1)) ;;
      --duplicate-of) dup=${ARGS[i+1]:-}; i=$((i+1)) ;;
      *) die "apply: unknown argument '${ARGS[i]}'" ;;
    esac
  done
  case "$verdict" in
    real|fixed|obsolete|duplicate|decision) ;;
    '') die "apply needs --verdict real|fixed|obsolete|duplicate|decision" ;;
    *) die "apply: --verdict must be real|fixed|obsolete|duplicate|decision, got '$verdict'" ;;
  esac
  [ -n "$evidence" ] || die "apply needs --evidence naming what the verifier found"
  [ "$verdict" != decision ] || [ -n "$question" ] ||
    die "apply --verdict decision requires --question naming what the captain must decide"
  [ "$verdict" = decision ] || [ -z "$question" ] ||
    die "apply: --question is only valid with --verdict decision"
  [ "$verdict" != duplicate ] || [ -n "$dup" ] ||
    die "apply --verdict duplicate requires --duplicate-of naming the finding it repeats"
  [ "$verdict" = duplicate ] || [ -z "$dup" ] ||
    die "apply: --duplicate-of is only valid with --verdict duplicate"
  [ "$dup" != "$id" ] || die "apply: a finding cannot duplicate itself"
  [ "$verdict" != duplicate ] || evidence="duplicate of $dup - $evidence"

  if [ "$ASANA" -eq 1 ]; then
    asana_apply "$id" "$verdict" "$evidence" "$question" "$dup"
    return
  fi

  # Read current state once, up front, for the idempotence and gate checks below.
  local held kind reason
  held=$(show_scalar "$id" held)
  [ -n "$held" ] || die "apply: no finding '$id' in $BACKLOG"
  kind=$(show_scalar "$id" hold_kind)
  reason=$(show_scalar "$id" hold_reason)

  case "$verdict" in
    fixed|obsolete|duplicate)
      # Closing is idempotent regardless of hold: an already-closed finding stays closed.
      if [ "$(show_scalar "$id" state)" = "done" ]; then
        echo "already-applied: $id already closed [$verdict]"
        return 0
      fi
      # An open finding must still be on OUR verify hold to close. A captain hold is a
      # human's decision/resource question; closing it fixed/obsolete would silently drop
      # that question - exactly the silent row this whole change exists to end.
      if fm_is_verify_hold "$kind" "$reason"; then
        apply_close "$id" "$verdict" "$evidence"
        return
      fi
      die "apply: $id is not on a verify hold (kind=${kind:-none}, held=$held) - it was already triaged; refusing to close it"
      ;;
  esac

  # real and decision act on the hold, so they require the finding to still BE on our verify
  # hold. If it is not, it was already triaged (or was never a queued finding), and re-acting
  # would re-open resolved work - refuse instead.
  if fm_is_verify_hold "$kind" "$reason"; then :; else
    if [ "$verdict" = real ]; then
      # Already dispatched, or already escalated by the safety floor on a prior identical
      # verdict - both are this same verdict already applied, so report and stop.
      if [ "$held" = no ]; then
        echo "already-applied: $id already dispatchable [real]"
        return 0
      fi
      case "$reason" in
        "captain: verified real but flagged"*)
          echo "already-applied: $id already escalated to the captain [real]"
          return 0
          ;;
      esac
    fi
    if [ "$verdict" = decision ] && [ "$kind" = captain ]; then
      echo "already-applied: $id already held for the captain [decision]"
      return 0
    fi
    die "apply: $id is not on a verify hold (kind=${kind:-none}, held=$held) - it was already triaged; refusing to re-open it"
  fi

  case "$verdict" in
    real)     apply_real "$id" "$evidence" ;;
    decision) apply_decision "$id" "$question" ;;
  esac
}

apply_close() {  # <id> <verdict> <evidence>
  local id=$1 verdict=$2 evidence=$3
  if axi "done" "$id" --note "triage: $verdict - $evidence" >/dev/null 2>&1; then
    echo "closed: $id [$verdict] - $evidence"
  else
    echo "fm-triage-findings.sh: could not close $id; it stays held" >&2
    return 1
  fi
}

apply_real() {  # <id> <evidence>
  local id=$1 evidence=$2 text marker
  text="$(show_scalar "$id" title)
$(show_body "$id")"
  marker=$(danger_marker "$text")
  if [ -n "$marker" ]; then
    # The safety floor: real, but destructive/irreversible/security-sensitive, so the machine
    # does not start it - it escalates to the captain like any section 8 item would.
    local reason
    reason="captain: verified real but flagged '$marker' - dispatch by hand, not by drain"
    if axi hold "$id" --reason "$(fm_sanitize_reason "$reason")" --kind captain >/dev/null 2>&1; then
      echo "escalated: $id verified real but matched danger marker '$marker'; held for the captain"
    else
      echo "fm-triage-findings.sh: could not escalate $id; it stays held" >&2
      return 1
    fi
    return 0
  fi
  if axi unhold "$id" >/dev/null 2>&1; then
    echo "dispatched: $id [real] - $evidence"
  else
    echo "fm-triage-findings.sh: could not clear the hold on $id; it stays held" >&2
    return 1
  fi
}

apply_decision() {  # <id> <question>
  local id=$1 question=$2
  if axi hold "$id" --reason "decision: $(fm_sanitize_reason "$question")" --kind captain >/dev/null 2>&1; then
    echo "escalated: $id [decision] - held for the captain: $question"
  else
    echo "fm-triage-findings.sh: could not re-hold $id for the captain; it stays held" >&2
    return 1
  fi
}

# --- Asana Triage ------------------------------------------------------------
asana_list() {  # <limit> <today-epoch>
  local limit=$1 today=$2
  [ "$limit" -gt 0 ] || return 0
  asana_open_cards "$ASANA_SECTION" "$WORK/cards.jsonl" "$limit" ||
    { echo "fm-triage-findings.sh: could not list Triage on board $ASANA_PROJECT: $API_ERR" >&2; return 1; }
  head -n "$limit" "$WORK/cards.jsonl" | jq -c --arg repo "$REPO" --arg p "$ASANA_PROJECT" --argjson now "$today" '
    (.notes // "") as $n | ($n | split("\n")) as $l |
    {id: .gid, title: (.name // ""),
     repo: ([$l[] | select(startswith("Repository: ")) | ltrimstr("Repository: ")] | first // $repo),
     where: ([$l[] | select(startswith("Where: ")) | ltrimstr("Where: ")] | first // ""),
     why: ($n | split("\nWhere: ")[0] | sub("^Issue\n"; "") | gsub("\\s+"; " ") | sub("^ "; "") | .[0:280]),
     expected: ([$l[] | select(test("^Expected( instead)?: ")) | sub("^Expected( instead)?: "; "")] | first // ""),
     severity: ([.tags[]?.name // "" | select(startswith("sev:")) | ltrimstr("sev:")] | first // ""),
     created: ((.created_at // "")[0:10]),
     age_days: (if (.created_at // "") == "" then null
                else (($now - ((.created_at[0:19] + "Z") | fromdate)) / 86400 | floor) end),
     url: ("https://app.asana.com/0/" + $p + "/" + .gid)}'
  [ -s "$WORK/cards.jsonl" ] || echo "list: no cards are waiting in Triage" >&2
}

# The gid of a named section on the target board, or "" when it has none. Dies when the board
# cannot be read, which leaves the card exactly where it was.
section_or_die() {  # <name>
  asana_section_named "$ASANA_PROJECT" "$1" ||
    { echo "fm-triage-findings.sh: could not read the sections of board $ASANA_PROJECT ($API_ERR); the card stays in Triage" >&2; exit 1; }
  printf '%s' "$SECTION_GID"
}

# Comment, then act: when the act fails the card is still in Triage, and a retry only adds a
# second comment.
asana_act() {  # <gid> <comment> <complete|section-gid> <done-line>
  local gid=$1 note=$2 act=$3 line=$4
  if asana_comment "$gid" "$note" && if [ "$act" = complete ]; then asana_complete "$gid"; else asana_move "$gid" "$ASANA_PROJECT" "$act"; fi; then
    echo "$line"
    return 0
  fi
  echo "fm-triage-findings.sh: could not update card $gid ($API_ERR); it stays in Triage" >&2
  return 1
}

asana_apply() {  # <gid> <verdict> <evidence> <question> <duplicate-of>
  local id=$1 verdict=$2 evidence=$3 question=$4 dup=$5 card completed onboard current marker queue="" captain=""
  case "$id" in *[!0-9]*|'') die "apply --asana needs a card gid, got '$id'" ;; esac
  asana_api GET "/tasks/$id?opt_fields=name,notes,completed,memberships.project.gid,memberships.section.gid" ||
    { echo "fm-triage-findings.sh: could not read card $id ($API_ERR); nothing changed" >&2; exit 1; }
  card=$API_BODY
  completed=$(printf '%s' "$card" | jq -r '.data.completed // false')
  onboard=$(printf '%s' "$card" | jq -r --arg p "$ASANA_PROJECT" '[.data.memberships[]? | select(.project.gid == $p)] | length')
  [ "$onboard" -gt 0 ] || die "apply: card $id is not on board $ASANA_PROJECT; refusing to touch it"
  current=$(printf '%s' "$card" | jq -r --arg p "$ASANA_PROJECT" '[.data.memberships[]? | select(.project.gid == $p) | .section.gid // ""] | first')

  case "$verdict" in
    fixed|obsolete|duplicate)
      if [ "$completed" = true ]; then
        echo "already-applied: $id already closed [$verdict]"
        return 0
      fi
      [ "$current" = "$ASANA_SECTION" ] ||
        die "apply: card $id is not in Triage - it was already triaged; refusing to close it"
      if [ "$verdict" = duplicate ]; then
        case "$dup" in *[!0-9]*) die "apply --asana: --duplicate-of needs a card gid, got '$dup'" ;; esac
        asana_api GET "/tasks/$dup?opt_fields=completed,memberships.project.gid" ||
          { echo "fm-triage-findings.sh: could not read card $dup ($API_ERR); card $id stays in Triage" >&2; return 1; }
        printf '%s' "$API_BODY" | jq -e --arg p "$ASANA_PROJECT" \
          '.data.completed != true and ([.data.memberships[]? | select(.project.gid == $p)] | length > 0)' >/dev/null ||
          die "apply: --duplicate-of $dup is not an open card on board $ASANA_PROJECT; refusing to close $id into it"
        # The repeat's evidence moves onto the card that stays open before this one closes, so
        # closing it loses nothing.
        asana_comment "$dup" "$(printf 'Duplicate closed into this card: %s\n%s\n\n%s' \
          "$(printf '%s' "$card" | jq -r '.data.name // ""')" "$(asana_url_for "$ASANA_PROJECT" "$id")" \
          "$(printf '%s' "$card" | jq -r '.data.notes // ""')")" ||
          { echo "fm-triage-findings.sh: could not comment on card $dup ($API_ERR); card $id stays in Triage" >&2; return 1; }
      fi
      asana_act "$id" "triage: $verdict - $evidence" complete "closed: $id [$verdict] - $evidence"
      return
      ;;
  esac

  [ "$completed" != true ] || die "apply: card $id is already closed; refusing to re-open it"
  captain=$(section_or_die "$CAPTAIN_SECTION_NAME") || exit 1
  if [ -n "$captain" ] && [ "$current" = "$captain" ]; then
    echo "already-applied: $id already with the captain [$verdict]"
    return 0
  fi
  if [ "$verdict" = real ]; then
    queue=$(section_or_die "$QUEUE_SECTION_NAME") || exit 1
    if [ -n "$queue" ] && [ "$current" = "$queue" ]; then
      echo "already-applied: $id already dispatchable [real]"
      return 0
    fi
  fi
  [ "$current" = "$ASANA_SECTION" ] ||
    die "apply: card $id is not in Triage - it was already triaged; refusing to re-open it"

  if [ "$verdict" = decision ]; then
    [ -n "$captain" ] || { echo "fm-triage-findings.sh: board $ASANA_PROJECT has no '$CAPTAIN_SECTION_NAME' section (captain-section=); card $id stays in Triage" >&2; return 1; }
    asana_act "$id" "$(printf 'triage: decision - %s\n\nEvidence: %s' "$question" "$evidence")" "$captain" \
      "escalated: $id [decision] - moved to '$CAPTAIN_SECTION_NAME': $question"
    return
  fi

  # Dedup merges repeats in as comments, so the floor reads them too.
  asana_api GET "/tasks/$id/stories?opt_fields=text,resource_subtype&limit=100" ||
    { echo "fm-triage-findings.sh: could not read comments on card $id ($API_ERR); it stays in Triage" >&2; return 1; }
  marker=$(danger_marker "$(printf '%s\n%s\n%s' "$(printf '%s' "$card" | jq -r '.data.name // ""')" "$(printf '%s' "$card" | jq -r '.data.notes // ""')" \
    "$(printf '%s' "$API_BODY" | jq -r '.data[]? | select(.resource_subtype == "comment_added") | .text // ""')")")
  if [ -n "$marker" ]; then
    [ -n "$captain" ] || { echo "fm-triage-findings.sh: card $id matched danger marker '$marker' but board $ASANA_PROJECT has no '$CAPTAIN_SECTION_NAME' section (captain-section=); it stays in Triage" >&2; return 1; }
    asana_act "$id" "triage: verified real but flagged '$marker' - dispatch by hand, not by drain. Evidence: $evidence" "$captain" \
      "escalated: $id verified real but matched danger marker '$marker'; moved to '$CAPTAIN_SECTION_NAME'"
    return
  fi
  [ -n "$queue" ] || { echo "fm-triage-findings.sh: board $ASANA_PROJECT has no '$QUEUE_SECTION_NAME' section (queue-section=); card $id stays in Triage" >&2; return 1; }
  asana_act "$id" "triage: real - $evidence" "$queue" "dispatched: $id [real] - $evidence"
}

# --- migrate -----------------------------------------------------------------
do_migrate() {
  [ ${#ARGS[@]} -eq 0 ] || die "migrate: unexpected argument '${ARGS[0]}'"
  local id kind reason created migrated=0 failed=0
  while IFS=$'\t' read -r id kind reason created; do
    [ -n "$id" ] || continue
    [ "$kind" = captain ] || continue
    [ "$reason" = "$GENERIC_HOLD_REASON" ] || continue
    if axi hold "$id" --reason "$FM_VERIFY_HOLD_REASON" --kind "$FM_VERIFY_HOLD_KIND" >/dev/null 2>&1; then
      migrated=$((migrated + 1))
    else
      failed=$((failed + 1))
      echo "fm-triage-findings.sh: could not migrate $id; left on its captain hold" >&2
    fi
  done < <(held_rows)
  echo "migrated: $migrated finding(s) onto the verify hold"
  [ "$failed" -eq 0 ] || return 1
}

case "$VERB" in
  list) do_list ;;
  apply) do_apply ;;
  migrate) do_migrate ;;
  *) die "unknown verb '$VERB' (expected list, apply, or migrate)" ;;
esac
