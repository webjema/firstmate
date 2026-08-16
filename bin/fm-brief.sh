#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks it fills in the standard Direction/Setup/Rules/Definition-of-done
# contract; firstmate then replaces the {TASK} placeholder with the task description,
# acceptance criteria, and context, and adjusts other sections only when the task
# genuinely deviates (e.g. working an existing external PR instead of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> [--scout]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list is cloned
#   into the secondmate home, while the natural-language scope tells the main firstmate
#   when to route work there; routine churn stays in its own home, and captain-relevant
#   escalations and marked from-firstmate replies append to this home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter.
# Every ship and scout brief opens with the project's Direction (bin/fm-direction.sh):
# the business vision and the architecture, infrastructure, and quality direction the
# change must move with. It is injected verbatim, on every task however small, because
# a bug fix that patches a symptom the architecture is trying to eliminate is a
# direction conflict, not a fix. A crewmate that cannot honor the direction escalates
# with needs-decision rather than quietly working against it.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see AGENTS.md task lifecycle):
#   PR          implement -> independent review + end-to-end exercise -> push the branch,
#               open NO PR -> report
#               `review-ready: branch fm/<id> pushed, no PR - reviewed by: <mechanism> -
#               <what it found>` and STOP (default).
#               Firstmate reviews the pushed branch against the direction; findings are
#               fixed in place and re-signalled `review-ready:`, and only an approval opens
#               the PR (plain gh) with `done: PR <url>`. The review gate sits BEFORE the PR so
#               a finding costs one fix, not a re-review plus a re-run of the crew's end-to-end
#               exercise and full suite and the PR's CI - the largest source of rework measured
#               in the fleet.
#               The push still happens, so the work is durable against a box reboot.
#   local-only  implement on branch, stop and report
#               `done: ready in branch fm/<id> - reviewed by: <mechanism> - <what it found>`
#               (no push/PR);
#               firstmate reviews, user approves, firstmate merges to local main
# Both modes require an INDEPENDENT review of the diff and name no command to get one.
# Naming one is unsafe in two directions: a harness may refuse to let an agent invoke its
# review command (Claude Code's built-in `/code-review` and `/verify` are both
# disable-model-invocation, i.e. runnable only in a turn a human typed them in, which a
# crewmate never has), and a same-named command from another source may review a different
# artifact (an already-open PR rather than the working diff). The scaffold therefore demands
# the OUTCOME - a fresh reader over the diff - and makes the crew report BOTH the mechanism and
# what the review found, on the status line it already writes. The outcome half is what makes
# the claim checkable: firstmate reads the same diff independently, so "no findings" on a diff
# with obvious defects is the tell that no review ran. A mechanism alone is unfalsifiable.
# The gate is built once by review_gate() and interpolated into both DODs, because two copies
# of one contract drift the moment only one is edited.
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Scout tasks ignore mode - their deliverable is a report, not a merge - but they still
# carry the direction, because a recommendation that ignores it is worthless.
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship and scout briefs carry a context-discipline block. When the project is
# actually indexed in the codebase-memory knowledge graph (checked at scaffold time
# via bin/fm-graph-lib.sh), that block also names the graph project, states the
# HEAD-pinned staleness boundary, and forbids the crew re-indexing; when it is not
# indexed, or the graph is unavailable, the guidance is absent rather than untrue.
# EVERY scaffold - ship, scout, and secondmate charter - carries the found-it-didn't-fix
# block: a finding that does not stop the crew finishing is filed as a tracked task with
# bin/fm-file-finding.sh and the crew keeps going, and a finding that DOES stop it is
# raised instead, never filed and abandoned. AGENTS.md section 5 owns the rule and the
# script's header owns the mechanics. It is built once by findings_block() and
# interpolated into all three, differing only in the command and in where the crew lists
# what it filed. Naming a command here is safe where naming a review command was not:
# this one is firstmate's own script, not something the harness may or may not expose.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path,
# and a quality-floor step so a project without Claude Code quality hooks gets them
# committed (bin/fm-hooks-install.sh) instead of relying on the agent's goodwill.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
KIND=ship
NO_PROJECTS=0
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --no-projects) NO_PROJECTS=1 ;;
    *) POS+=("$a") ;;
  esac
done
ID=${POS[0]}

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")

# Shared context-discipline block, injected verbatim into ship and scout briefs so
# a long task keeps its own working context lean. One owner: the same guidance is
# never written twice. See docs/proposals/context-management.md (Layer 1, reduce
# inflow) - a crew that keeps only conclusions reaches its window far more slowly.
CONTEXT_DISCIPLINE=$(cat <<'EOF'
# Context discipline
Keep your own working context lean so a long task never crowds out the work itself.
- Investigate through your harness's read-only exploration subagent where it has one, so file contents and search output come back as a short conclusion instead of filling your main context.
- Read only what you need: prefer targeted reads over whole files, and never re-read a file you already understand.
- Capture large command output - test runs, builds, long logs - to a file and read only the tail or the failing lines, rather than streaming all of it through your context.
- Keep a short running plan in a scratch file in your worktree (`.fm/progress.md`: what is done, what is left, key findings), and update it as you go; it is scratch, so never stage or commit it. Your context may be compacted mid-task; the plan file and your commits are what let you resume without losing your place, so treat them as your durable memory, not your chat history.
EOF
)

# Shared found-it-didn't-fix block, in EVERY mode. A scout that trips over three defects
# while investigating a fourth is the highest-value case for it, so it is not a ship-only
# clause. AGENTS.md section 5 owns the rule and bin/fm-file-finding.sh owns the mechanics;
# this is the crew-facing statement of the same contract, because a crewmate never reads
# firstmate's AGENTS.md. Two parameters only: the command, and where the crew lists what
# it filed.
# Unlike the review gate, this DOES name a command - the reasoning there was that firstmate
# cannot know which commands a HARNESS exposes. This one is firstmate's own script, always
# present, exactly like fm-hooks-install.sh and fm-ensure-agents-md.sh below.
findings_block() {  # <command-prefix> <where-to-list-them>
  local cmd=$1 list=$2
  cat <<EOF
# Findings you did not fix
You will notice defects and risks that are not part of this task. A report is not a queue: a finding you only write up is read once and never becomes work.
**One question decides what happens, and it is the only one: does this stop you finishing THIS task?**
- **No** - file it as a tracked task and keep going. Do not fix it, do not widen your diff, do not stop to ask whether it is worth filing:
  \`$cmd --blocking no --title "<what is wrong>" --where "<file:line>" --why "<why you believe it is wrong>" --expected "<what you expected instead>"\`
  File it the moment you find it rather than batching them to the end, because a compaction or a crash between finding and filing is exactly how findings are lost. The script picks the right tracker, refuses to file the same finding twice, and holds it locally when a tracker is unreachable - so it never fails your task and never drops the finding. Add \`--priority 0-4\` when the severity is worth recording.
- **Yes** - it blocks you, and filing is not a way past it. Fix it only if the scope is small and clearly adjacent, and say that you did; otherwise append \`blocked:\` or \`needs-decision:\` under the Rules above and stop. The script refuses \`--blocking yes\` for exactly this reason.
Severity, whose code it is, and whether it feels worth someone's time set the filed task's priority; they never decide whether to file.
$list
EOF
}

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You own this domain end to end.
Act on the work routed to you, keep it moving, and escalate a decision beyond your judgment upward rather than stalling on it.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Each project you supervise has a standing direction at \`data/directions/<project>.md\`: the business vision and the architecture, infrastructure, and quality direction that every change must move with. Read it before you dispatch anything, brief your crewmates with it, and judge their work against it.
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work; act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate (your supervisor) is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
A message with NO marker is the user typing directly into your pane: treat it as authoritative user intervention and stay conversational exactly as you would for any user message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a user decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
When a decision you escalated is answered or a blocker clears and your domain resumes, append \`resolved: {how it was decided or unblocked}\` (keyed with \`[key=<slug>]\` if you opened it with one) so it is durably closed instead of resurfacing behind later unrelated events.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

$(findings_block 'bin/fm-file-finding.sh' 'Name every finding you filed when you report the outcome, so the main firstmate can relay it; brief your own crewmates with this same rule.')

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

# A crew's shell does not inherit FM_HOME (bin/fm-spawn.sh forwards credentials, not
# firstmate's own env), so the home is pinned into the command the brief names; without
# it a crew would file into whichever home owns bin/, which is the wrong one for a
# secondmate's crew.
CREW_FILE_CMD="FM_HOME=$(shell_quote "$FM_HOME") $(shell_quote "$FM_ROOT/bin/fm-file-finding.sh") --task $ID"

# Graph guidance, appended to the context-discipline block for ship and scout
# briefs. TRUTHFUL OR ABSENT: emitted only when this project is actually in the
# codebase-memory graph, checked here at scaffold time, because a brief that sends
# a crew to query an index that does not exist is worse than saying nothing. The
# check is best-effort - no binary, no jq, a CLI error, or an unindexed project all
# yield an empty block and a brief that scaffolds normally.
graph_guidance() {
  local dir=$1 name
  [ "$(fm_graph_mode)" != off ] || return 0
  name=$(fm_graph_project_for_path "$dir" 2>/dev/null) || return 0
  cat <<EOF

- This project is indexed in the \`codebase-memory\` knowledge graph as project \`$name\`: query it (\`search_code\`, \`search_graph\`, \`get_architecture\`, \`trace_path\`) to locate and understand code instead of grepping the tree into your context. The \`codebase-memory\` skill documents the query surface.
- The index is pinned to the clone's HEAD, not your branch, so it is sound for reading code you have NOT changed and wrong for verifying your own diff: use \`detect_changes\` to map your local changes onto it, and your own reads and tests for anything about your diff.
- Never index or re-index anything yourself: that would multiply cost and pollute the graph with per-branch projects. Keeping it fresh is firstmate's job.
EOF
}

GRAPH_DIR=$REPO
if [ ! -d "$GRAPH_DIR" ]; then
  GRAPH_DIR="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}/$REPO"
fi
if [ -d "$GRAPH_DIR" ]; then
  # shellcheck source=bin/fm-graph-lib.sh
  . "$SCRIPT_DIR/fm-graph-lib.sh"
  CONTEXT_DISCIPLINE="$CONTEXT_DISCIPLINE$(graph_guidance "$GRAPH_DIR")"
fi

# The project's standing direction, injected verbatim into every brief.
DIRECTION_SECTION=$("$FM_ROOT/bin/fm-direction.sh" brief "$REPO")

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You own this investigation end to end.
Follow the Direction below and keep the work moving.
When you hit a decision beyond your judgment, escalate it through the status channel in the Rules - this window is not monitored, so never wait for a reply here.

# Task
{TASK}

$DIRECTION_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
Before starting any work, read the project's \`CLAUDE.md\` and \`AGENTS.md\` at the repo root, and follow any imports or parent-guide pointers they reference (for example a nested example project whose \`AGENTS.md\` points to a parent \`../../AGENTS.md\`), so you understand the project's rules, conventions, and architecture first.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

$CONTEXT_DISCIPLINE

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use \`gh-axi\` for GitHub reads (\`pr list/view\`, \`run list/view\`, \`issue list\`, \`search\`) - same \`gh\` auth, far smaller output - and plain \`gh\` for mutations (\`pr create\`, pushes) and anything scripts or CI depend on.
   On any \`gh-axi\` error, fall back to plain \`gh\` instead of debugging the wrapper.
   Use chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks on a long cadence instead of treating
   it as a wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.

$(findings_block "$CREW_FILE_CMD" 'List every finding you filed in your report, with its filed-task reference, so the report says what became work and what is still only a recommendation. A defect you tripped over while investigating something else is the case this rule exists for.')

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
Judge every option you recommend against the Direction above, and say so explicitly: a recommendation that moves against the project's architecture, infrastructure, or quality direction is not a recommendation, it is a trap. If the best technical answer conflicts with the direction, present that conflict as the finding.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ship task: shape Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief (it governs firstmate's approval behaviour), so discard it.
read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF

# The review gate is identical in both delivery modes, so it is built once here and
# interpolated into each DOD rather than written twice: two copies drift the moment
# only one is edited. Only the line the crew reports it on differs, so that is the
# single parameter. $REPORT_LINE names it (a `review-ready:` or a `done:` line).
review_gate() {
  local report_line=$1
  cat <<EOF
2. Obtain an INDEPENDENT code review of your diff and fix what it finds.
   Do not assume any particular review command exists. This brief deliberately names none: firstmate cannot know which commands your harness exposes, some harnesses refuse to let an agent invoke its review command at all, and a command that shares a name across harnesses can review a different artifact than your working diff.
   Use whatever your harness actually provides. A review subagent handed your diff works on every harness and is always an acceptable choice.
   It must be a fresh reader over the diff, not you re-reading your own work.
   **Report the review on your $report_line, as \`reviewed by: <mechanism> - <what it found>\`.** Name the mechanism, then say what came back: the findings you acted on, or \`no findings\` if it genuinely returned none.
   Naming a mechanism but no outcome does not count: firstmate reads the same diff independently, and a review that found nothing worth reporting on a diff with obvious defects is how it detects a review that never ran. Reporting nothing at all means the review did not happen and firstmate will send it back.
   Fix the real findings yourself. A finding that turns on a human judgment call - a product choice, a destructive or irreversible action, a security trade-off - is NOT yours to decide: escalate it under rule 6 and stop.
3. Exercise the change end-to-end - drive the affected flow in the real app, not just the tests.
   Do not assume a named command for this either; use whatever your harness provides.
EOF
}

case "$MODE" in
  local-only)
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    DOD=$(cat <<EOF
# Definition of done
This project ships **local-only**: no remote, no PR.

1. Implement the change and commit it on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
   Run the tests your change AFFECTS as you go. Run the project's FULL suite EXACTLY ONCE, at the end, before step 6 - not after every edit.
$(review_gate "\`done:\` line at step 6")
4. Direction check: in one line, state how this change honors the Direction above. If it moves against the direction, stop and escalate under rule 6 instead of shipping it.
5. Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
6. Append \`done: ready in branch fm/$ID - reviewed by: {mechanism} - {what it found}\` to the status file and stop, filling in both halves from step 2.

Firstmate then reviews your branch diff against the project's direction, the user approves, and firstmate merges it into local \`main\`.
EOF
)
    ;;
  *)  # PR (default)
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never open a PR before firstmate approves your branch (see Definition of done). Never merge a PR.'
    DOD=$(cat <<EOF
# Definition of done
This project ships by **pull request**, but the PR is the LAST step, not the first.
Firstmate reviews your pushed branch BEFORE any PR exists, so its findings cost you a fix on the same branch - not a re-review, a re-run of CI, and a churned PR.

1. Implement the change and commit it on your branch.
   Run the tests your change AFFECTS as you go. Run the project's FULL suite EXACTLY ONCE, at the end, before step 6 - not after every edit. Re-running the whole suite per edit was the single biggest time sink measured in this fleet.
$(review_gate "\`review-ready:\` line at step 6, and again in the PR body at step 7")
   **State in the PR body how you exercised it.**
4. Satisfy the project's quality hooks. They run automatically on commit and push (secret scan, lint, typecheck, tests). A blocked commit or push means the gate caught something real; fix the cause, never work around the gate.
5. Direction check: in one line, state how this change honors the Direction above.
   If the task as specified would move AGAINST the direction, do not quietly implement it - escalate under rule 6.
6. **Push your branch. Open NO PR.** The push makes your work durable; the PR would only make firstmate's review expensive to act on.
   Append \`review-ready: branch fm/$ID pushed, no PR - reviewed by: {mechanism} - {what it found}\` to the status file and STOP, filling in both halves from step 2. Firstmate now reviews your diff against the direction.
7. Firstmate replies with one of two things:
   - **Findings.** Fix them IN PLACE on the same branch, push again, and append \`review-ready:\` again, reporting the review of what you changed this round. Repeat until firstmate approves. No PR exists yet, so there is nothing to churn.
   - **Approval.** Open the PR with plain \`gh\` (\`gh pr create\`), stating in the body how you reviewed and exercised the change, append \`done: PR {url}\` to the status file, and stop.

Do NOT merge the PR, and do not wait for CI yourself. Firstmate watches CI; the user merges.
Once the PR is open your work is on the remote, so firstmate releases your worktree at that point - finish step 7 and stop cleanly.
EOF
)
    ;;
esac

cat > "$BRIEF" <<EOF
You own this task end to end.
Follow the Direction below and keep the work moving.
When you hit a decision beyond your judgment, escalate it through the status channel in the Rules - this window is not monitored, so never wait for a reply here.

# Task
{TASK}

$DIRECTION_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` help inspect the repo but cannot prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b fm/$ID\`
2. Read the project's \`CLAUDE.md\` and \`AGENTS.md\` at the repo root before starting any work, and follow any imports or parent-guide pointers they reference (for example a nested example project whose \`AGENTS.md\` points to a parent \`../../AGENTS.md\`), so you understand the project's rules, conventions, and architecture first.

$CONTEXT_DISCIPLINE

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use \`gh-axi\` for GitHub reads (\`pr list/view\`, \`run list/view\`, \`issue list\`, \`search\`) - same \`gh\` auth, far smaller output - and plain \`gh\` for mutations (\`pr create\`, pushes) and anything scripts or CI depend on.
   On any \`gh-axi\` error, fall back to plain \`gh\` instead of debugging the wrapper.
   Use chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, review clean) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks on a long cadence
   instead of treating it as a wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions, a conflict with the Direction above),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.

$(findings_block "$CREW_FILE_CMD" 'List every finding you filed, with its filed-task reference, in the summary you report at the end and in the PR body if you open one.')

# Quality floor
The project's Claude Code hooks are the mechanical floor: they enforce secret-scanning, lint, typecheck, and tests whether or not you cooperate.
Run \`$FM_ROOT/bin/fm-hooks-install.sh .\` in the worktree. If the project already has hooks it will say so and change nothing; if it has none, it installs a starter bundle you should tune to this project and commit with your change.
Never disable, bypass, or work around a hook. A blocked commit or push is the floor doing its job.

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.
Project-intrinsic knowledge goes in \`AGENTS.md\`. The Direction above is the user's and lives with firstmate - never copy it into the project.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
