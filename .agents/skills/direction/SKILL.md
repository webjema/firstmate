---
name: direction
description: Author, review, and evolve a project's standing direction - its business vision and its architecture, infrastructure, and quality direction. Use when the user invokes /direction, asks to set or change a project's direction, vision, architecture, or quality bar, or when a resolved user decision established a standing principle that should bind future work. Also use before answering a crewmate's needs-decision that turns on product intent or architectural posture.
user-invocable: true
metadata:
  internal: true
---

# direction

A project's direction is the answer to "what are we actually building, and what does good look like here".
It is the user's, not the project's, so it lives with firstmate at `data/directions/<project>.md` and never inside the repo.

Every ship and scout brief injects it verbatim, on every task however small.
That is the point: a bug fix that patches a symptom the architecture direction is trying to eliminate is a direction conflict, not a fix.

## The four axes, plus the ledger

`bin/fm-direction.sh` owns the file format, the required headings, and the word cap.
Run `bin/fm-direction.sh init <project>` to scaffold, and `bin/fm-direction.sh check` to validate.

- **Business vision** - what the product is for, who it serves, what winning looks like.
- **Architecture direction** - the target shape, the invariants that must hold, what we are moving toward and away from.
- **Infrastructure direction** - deploy, ops, and cost posture; what runs where, and what we refuse to run.
- **Quality direction** - test posture, what "good" means here, the non-negotiables, and the debt knowingly accepted.
- **Standing decisions** - dated one-liners, grown from the user's answers, so a decision made once is never re-litigated by the next crewmate.

## Authoring

The user rarely has this written down, so do not ask them to write an essay.
Draft it from what you can read - the project's `README`, its `AGENTS.md`, its recent merged PRs, the shape of its dependencies - and put a concrete proposal in front of them to correct.
A wrong first draft they can red-pen is worth more than a blank template they will not fill in.

The business vision is the one axis you cannot infer.
Guess it explicitly, mark the guess, and make it the first thing you ask about.

Keep it under the word cap.
It is injected into every brief for that project, so a direction that grows into a design doc stops being read, which is the only failure mode that matters.
Prefer a sharp sentence over a complete one: "every write goes through a command handler; no lambda touches Dynamo directly" beats a paragraph about CQRS.

## The four gates

Direction is worthless if it only exists in a file. Apply it at every point where judgment enters the fleet:

1. **Intake.** Before dispatching, judge the request against the direction and say in one line how it sits. If the user has asked for something that moves against the stated direction, say so *before* burning a crew on it - they may have changed their mind, and that is a direction update, not a task.
2. **Brief.** Automatic: `bin/fm-brief.sh` injects the direction into every ship and scout brief, with the conflict-escalation contract.
3. **Answering a `needs-decision`.** Load the direction before you answer. A crewmate's question about which way to build something is a direction question; answer it from the direction, not from local convenience. If the direction does not settle it, that is a gap - take it to the user and then record the answer.
4. **Pre-merge review.** Review the diff against the direction (`bin/fm-review-diff.sh <id>`) before relaying to the user. Mechanical quality is the hooks' and CI's job; *this* review is for drift. Say plainly if the change works but pulls the architecture the wrong way.

## The ledger is the whole point

When the user resolves a question that will recur - "no, we never add a second source of truth for supplier state", "yes, alpha may lag prod by a release" - append it to `## Standing decisions` with the date.
Do this the moment it is answered, not later.
An answer that lives only in a chat transcript will be re-asked by the next crewmate, and the user will answer it again, and be right to be annoyed.

The same applies in reverse: when a standing decision is overruled, rewrite it. Do not append a contradiction.
Curate this file the way `data/user.md` and `data/learnings.md` are curated - inspect, then rewrite or prune - never append forever.

## Relationship to other memory

Direction answers "where are we going and what is good".
It is not project documentation and not fleet trivia.

- Project-intrinsic knowledge - how to build, test, and deploy this repo - belongs in the project's own `AGENTS.md`, via normal crewmate delivery. Never copy the direction into the project.
- User preferences and working style belong in `data/user.md`.
- Fleet-local operational gotchas belong in `data/learnings.md`.
