---
name: triage
description: Drain the fleet finding queue - verify each finding held for automated triage against the current code, then dispatch the real ones, close the fixed or obsolete ones, and escalate only a genuine product or access question. Use when the session digest reports findings awaiting the triage drain, when the fleet is otherwise idle, or when the user invokes /triage. It is the judgment half of bin/fm-triage-findings.sh, which does the mechanics.
user-invocable: true
metadata:
  internal: true
---

# triage

A filed finding used to sit under a captain hold until a human read it, and almost none of them needed a human: a measured queue of 44 held every one for a review that 41 never required.
So the default flipped.
A finding is now filed under a machine-drainable **verify** hold, and this skill is what drains it: it verifies the finding against the code as it stands today and acts on what it finds, with a human touched only for a real product or access question.

The split is deliberate.
`bin/fm-triage-findings.sh` is the mechanical half - it lists the queue and applies a verdict, and it never opens the file a finding points at.
This skill is the judgment half - it reads the code and decides the verdict.
Neither half judges the other's job: the script does not guess whether a finding still reproduces, and this skill does not hand-edit holds.

## When this fires

- The session-start digest reports findings **awaiting the triage drain**, and the fleet is otherwise idle.
- The user invokes `/triage`.
- You have just filed a batch of findings and want them verified now rather than at the next session.

Draining competes with live supervision for one thread of attention, so drain when the fleet is quiet, not while you are steering crews.
The queue does not rot - a held finding waits safely - so there is no urgency that overrides supervision.

## The one thing this skill must never do

**Never dispatch a finding you have not verified in the current code.**
The whole point of the flip is that a machine verifies before work starts; skipping the read and dispatching on the finding's say-so re-creates the exact bug where unreviewed findings became work.
A finding is a claim made at some past moment about some past state of the code.
Your job is to decide whether it is still true now.

## Running a drain

### 1. Pull a bounded batch

```sh
bin/fm-triage-findings.sh list
```

It prints one JSON object per line - `id`, `title`, `repo`, `where` (the `file:line` the finding names), `why`, `expected`, `created`, `age_days` - capped at a handful so you verify a batch rather than the whole queue.
An empty list means the queue is drained; stop.
Pass `--limit N` to size the batch to how much verification you can give it in one pass.

### 2. Verify each finding against the code as it stands

This is the judgment, and it is a **fresh read of the current code**, not a re-reading of the finding.
Hand the batch to a verification agent whose whole task is: for each finding, open `where` in the repository it names, decide whether the defect the finding describes still reproduces there today, and return a verdict with the evidence that settles it.
Delegate it - the read is project-specific work and its file dumps do not belong in your context - and require one verdict per finding, each carrying the `file:line` and the fact that decided it.

The verdicts, and what each means:

- **fixed** - the code already does the right thing. The defect the finding describes is not present at `where` (or wherever it moved). Evidence names the code that fixes it. Filings that were already resolved between filing and now land here, and they must close on the evidence, not be dispatched as if still open.
- **obsolete** - the finding no longer applies at all: the code it pointed at is gone, the design changed out from under it, or a later correction in the finding's own body withdrew it. Evidence names what makes it moot.
- **real** - the defect still reproduces in the current code. Evidence names the line and the failure. This one becomes work.
- **decision** - verifying it surfaced a genuine product or architecture call that only the captain can settle - which way to build the fix, not whether the bug is real. This is the only verdict that reaches a human, and it must carry the exact question.

When the read is ambiguous - you cannot tell whether it reproduces without running it, or the finding is too vague to check - prefer **real**: a verified-later dispatch is cheaper than a wrongly-closed defect.

### 3. Apply each verdict

One call per finding, and the evidence is not optional - a closed finding must say why it closed:

```sh
bin/fm-triage-findings.sh apply <id> --verdict fixed    --evidence "<what makes it already-fixed, with file:line>"
bin/fm-triage-findings.sh apply <id> --verdict obsolete --evidence "<what makes it moot>"
bin/fm-triage-findings.sh apply <id> --verdict real     --evidence "<the line and the failure>"
bin/fm-triage-findings.sh apply <id> --verdict decision --evidence "<what you verified>" --question "<the exact call the captain must make>"
```

`apply` never drops a finding: a tracker failure leaves the finding on its hold, so a half-applied batch loses nothing.
Recover by re-running `list` and applying only what it still returns - `list` shows only open verify holds, so a finding you already resolved never comes back.
Do not re-apply from a saved id list: a re-apply is a no-op only while the finding is still visible, and closing more than ten findings prunes the oldest closed ones off the tracker, so a stale id then errors instead.

**The safety floor is the script's, not yours.**
`apply --verdict real` scans the finding's own text for anything destructive, irreversible, or security-sensitive - privilege, secrets, history rewrites, data deletion, production deploys - and on a match it escalates to the captain instead of dispatching, whatever your verdict.
So you verify honestly and let the floor catch the dangerous ones; you do not have to hand-hold them, and you cannot override it by calling something real.
When you see `escalated:` on a `real` verdict, that is the floor doing its job.

### 4. Loop, then report the split

Repeat from step 1 until `list` is empty.
Then tell the captain the outcome in plain terms - how many findings became work, how many closed as already-fixed or obsolete, and every question that now needs their call, each with its finding.
Report the questions as questions, not as "the drain is done": the dispatched and closed findings are bookkeeping, but an escalated decision is the one thing that was actually waiting for them.

## The first drain of an old queue

A queue filed before the default flipped is still held the old way - kind captain, the generic reason "unreviewed finding - triage before dispatching".
Move it onto the verify hold once, before the first drain:

```sh
bin/fm-triage-findings.sh migrate
```

It re-labels only the generically-held rows and leaves a real captain question alone, and it is idempotent.
A second run reports nothing left to migrate.
After that the queue drains like any other.
