---
name: capture-decision
description: Capture a human-driven decision or correction into the right firstmate knowledge home so it binds future work. Use automatically whenever the user makes a durable call - product intent, an architecture or quality posture, a working-style preference, or a fleet-local fact - or corrects a choice you made, and on an explicit /decide or /remember. Records without asking, generalizes the principle, routes by kind, and curates in place.
user-invocable: true
metadata:
  internal: true
---

# capture-decision

The user's decisions and corrections are the most valuable input firstmate gets, and the failure this skill exists to prevent is losing them: a decision that lives only in a chat transcript is re-litigated by the next crewmate, and a correction you do not record you will make again.
So capture is **automatic** - you record durable input the moment it lands, without asking - and **routed by kind**, so it reaches the home that actually binds future work.

## When this fires

Load this whenever, in the normal flow of a conversation, the user:

- makes a call about **what to build or why** (product intent, priorities, what winning looks like),
- sets or shifts an **architecture, infrastructure, or quality** posture ("we never add a second source of truth", "alpha may lag prod by a release", "root-cause fixes only"),
- states a **working-style preference** about how firstmate itself should operate ("always show me the full PR URL", "don't ask before routine approvals on repo X"),
- gives a **fleet-local operational fact** or gotcha, or
- **corrects** a decision you made or a default you assumed.

It also fires on an explicit `/decide` or `/remember`.
A one-off instruction for the task in front of you is not a durable decision - it belongs in that task's brief or backlog note, not here.

## The four moves

### 1. Generalize before you record

Record the reusable **principle**, not just the instance.
When the user corrects one case, ask what rule the correction implies and write that rule; keep the concrete case only as a sharpening example when the rule alone would be ambiguous.
"Don't hand-edit the capped direction file" generalizes a correction about one file into a rule that prevents the whole class.
Convert every relative date to an absolute one, and strip volatile specifics (temp paths, in-flight versions, ephemeral ids) that would rot - reference the authoritative source instead of copying it.

### 2. Route by kind

| What the user just decided | Home | How |
| --- | --- | --- |
| A resolved, recurring answer for one project ("we never do X here") | that project's `## Standing decisions` | `bin/fm-direction.sh add-decision <project> "<generalized one-liner>"` |
| A shift in a project's business vision, or its architecture / infrastructure / quality posture itself | that axis in `data/directions/<project>.md` | load `direction`; inspect then rewrite that axis |
| How firstmate should work with them (preference, working style) | `data/user.md` | inspect, then rewrite in place |
| A fleet-local operational fact or gotcha | `data/learnings.md` | inspect, then rewrite in place |
| Something true for every firstmate user, not just this one | `AGENTS.md` | ship via PR (the normal repo gate) |

Route by the **nature** of the decision, not by the project last discussed.
When a decision is genuinely project-scoped, prefer the project's direction over `user.md`, because the direction is injected into every crewmate brief and so binds the work directly.

### 3. Curate, do not append

Every one of these homes is inspected, then rewritten - never appended to forever.
`add-decision` already handles the ledger mechanics (dated, newest-first, placeholder-aware, word-cap-validated); before you call it, check whether an existing standing decision is superseded and rewrite that one instead of stacking a contradiction.
For `user.md` and `learnings.md`, read the current file, decide whether the input is new, a duplicate, a superseding update, or now-obsolete, and write a considered replacement.
If `add-decision` returns non-zero because the direction is now over its word cap, that is the signal to curate the ledger down, not to stop recording.

### 4. Confirm terse, never ask

Capture is automatic and silent: you record without a confirmation prompt.
Leave a one-line trail in your reply so the user can catch a miscategorization - `(noted in optiroq direction: supplier state has one source of truth)` - and move on.
Never turn a capture into a question.

## The two hard edges that still escalate

Automatic capture does not override firstmate's standing escalation rules:

- If the user's decision **reverses a standing direction**, record the reversal (rewrite the superseded decision), and surface the conflict to the user per AGENTS.md section 5 - a direction conflict is never resolved silently.
- If routing is **genuinely ambiguous** (the decision could be product intent or a working-style preference and the two would bind different work), ask the one-line routing question rather than guessing a home.

Everything else: generalize, route, curate, note it in one line, carry on.
