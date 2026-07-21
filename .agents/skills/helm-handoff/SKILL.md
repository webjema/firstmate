---
name: helm-handoff
description: Prepare firstmate's own session for a lossless context reset. Use when the user asks firstmate to reset/compact/"hand off the helm" because its context is getting full, or when a self context read (bin/fm-context-gauge.sh --self) reports level high or critical. Flushes any volatile in-head state to its durable homes and refreshes the bearings checkpoint, so that whenever auto-compaction or a restart fires, the session resumes with nothing lost. Read-mostly: it externalizes state and writes the bearings report, and never merges, tears down, or dispatches as a side effect.
user-invocable: true
metadata:
  internal: true
---

# helm-handoff

Prepare the firstmate session for a lossless context reset.

Firstmate's design already makes a restart a non-event (AGENTS.md section 4).
This skill closes the one gap that assumption depends on - that nothing important lives ONLY in the current chat - and it does so BEFORE a reset, not after, so an auto-compaction that fires at the ceiling or a deliberate restart loses nothing.

Invoke it when the user says firstmate is getting full and should reset, compact, or "hand off the helm", or when `bin/fm-context-gauge.sh --self` reports `level: high` or `critical`.

## What it does

1. **Flush volatile in-head state to its durable home.**
   Walk what is live in this conversation and route anything not already persisted, using the section 5 knowledge-routing table:
   - a decision the user resolved that will recur -> the project's `## Standing decisions` via `bin/fm-direction.sh add-decision` (load `capture-decision`);
   - a working-style preference or a fleet-local fact -> `data/user.md` / `data/learnings.md` (load `capture-decision`);
   - an in-flight task's current judgment, next step, or open question -> that task's note (`tasks-axi update <id> --body-file`), inspected-then-replaced per section 9;
   - an investigation finding not yet written down -> the scout report or a `data/` doc.
   Nothing that matters may be left only in the chat.
   If a pending decision is still unresolved, it belongs to the user: surface it now rather than burying it in a reset.

2. **Confirm the fleet records match reality.**
   The backlog In flight / Queued / Done, and each `state/<id>.meta`, must reflect the true current state, since recovery reads them and not the chat.
   Correct any drift you are already aware of; do not launch a fresh investigation.

3. **Refresh the bearings checkpoint.**
   Run the `bearings` skill (or `bin/fm-bearings-snapshot.sh`) to write the dated "pick up where I left off" report to `data/`.
   That report plus the durable state above is the whole resume surface.

4. **Hand off.**
   Tell the user the session is checkpointed and safe to reset, and how the reset will happen:
   - if the primary was launched with the auto-compact env (see the context-management configuration reference), it will auto-compact around the ceiling on its own, and this preparation is what makes that compaction lossless;
   - otherwise a restart is safe now - recovery through `bin/fm-session-start.sh` reconstructs the full session from the state just flushed.
   Firstmate cannot run `/compact` on its own session; a seeded `/compact <focus>` is the user's to invoke if they want an immediate manual compaction rather than waiting for the automatic one.

## Discipline

This skill is read-mostly.
It externalizes state and writes exactly the bearings report and the durable notes above.
It never merges a PR, tears down a task, dispatches new work, or otherwise mutates fleet state as a side effect of preparing the handoff - those remain the user's explicit word and the normal task lifecycle.
