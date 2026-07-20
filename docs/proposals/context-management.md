# Proposal: context management (keep every firstmate and crew session under its window)

Status: draft for sign-off.
Scope: firstmate's own primary session and its crewmates and secondmates.
Goal: every session stays below a hard ceiling (target 200,000 tokens) at all times, with no lost work.
Harness posture: full stack on Claude/Agent-SDK, a bounded-tools-plus-reset floor on codex, opencode, pi, and grok.

## 1. What this is

A long-running firstmate session accumulates context the same way any agent does: every wake, pane peek, crew-state read, review diff, and fleet snapshot adds tokens, and a supervising session lives for hours across many tasks.
Crews carry even more risk per session, because they do the heavy reads, run `/code-review`, `/verify`, and full test suites, and today get zero context guidance in their brief.
Left alone, both drift toward the window limit, and the harness falls back to lossy auto-compaction that keeps what it guesses is important rather than what firstmate chose.

This proposal makes context reset a routine, lossless, first-class operation rather than a crash-only event.
It rests on a property firstmate already has that most agents lack: a stateless core backed by durable external state.
`AGENTS.md` already states it - "your conversation memory is a cache, and all truth lives in tmux, `state/`, `data/`, and secondmate homes" and "a firstmate restart must be a non-event."
Crews have the same property through their worktree, branch, commits, and status file.
Because the truth already lives outside the conversation, a session can be reset to a fresh, reconstructed context and lose nothing.

## 2. The contract (target behavior)

- Every firstmate, crew, and secondmate session stays below the configured hard ceiling at all times.
- Staying under the ceiling never discards unlanded work, a pending decision, or an in-flight plan.
- Reset is deliberate and seeded: firstmate and crews choose what survives a reset, rather than accepting whatever auto-compaction keeps.
- The mechanism degrades gracefully: best behavior on capable harnesses, a working floor on every verified harness.
- Observability comes first: firstmate can read where any session sits before it acts on it.

## 3. The three layers

Defense in depth.
Layers 1 and 2 make resets rare; layer 3 makes the ceiling hard.

### Layer 1 - reduce inflow

Spend fewer tokens per unit of work, so a session reaches the ceiling far more slowly.

**1A. Auto-compaction tuned to the ceiling (claude), context editing where available.**
Firstmate's tool results are almost all reconstructable-on-demand: a pane peek, a crew-state read, or a review diff from thirty turns ago has zero forward value, and the underlying truth is still on disk.
The ideal mechanism is the platform `clear_tool_uses` context-editing strategy - clear stale `tool_result` blocks, keep the reasoning, with the `state/` and `data/` files acting as the memory the cleared results would otherwise hold.
That strategy, however, is exposed only through the Claude API and Agent SDK, not the Claude Code CLI that firstmate and its crews actually run on (verified against the Claude Code docs, 2026-07).
The CLI-native equivalent that keeps a claude session under the managed ceiling is auto-compaction tuning: launching each claude session with `CLAUDE_CODE_AUTO_COMPACT_WINDOW=<ceiling>` and `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=<pct>` makes it auto-compact around the ceiling instead of the model's full 200K or 1M window, so it never exceeds the ceiling - the harness enforces the bound natively.
This ships in the crew spawn path; the primary session is launched with the same env.
See [context editing](https://platform.claude.com/docs/en/build-with-claude/context-editing), the [context-management guidance](https://claude.com/blog/context-management), and the Claude Code [env-vars reference](https://code.claude.com/docs/en/env-vars).

**1B. Enforce bounded reads in the hot loop.**
The bounded, deterministic tools are firstmate's signature move and already strong: `fm-crew-state.sh` returns one line, `fm-peek.sh` defaults to forty, `fm-bearings-snapshot.sh` and `fm-fleet-snapshot.sh` render a projection the model reads instead of raw files, and `gh-axi` emits TOON.
This step audits every read path the primary hits repeatedly and caps anything that can still stream unbounded, then reinforces the behavioral half already in `AGENTS.md`: act on the wake payload, read nothing further unless it is self-contradictory or absent.

**1C. Subagent-first crew work.**
The largest single crew lever: a subagent that reads thousands of tokens of files returns a short conclusion, and the file content never touches the crew's main thread.
Add a context-discipline section to the crew brief in `bin/fm-brief.sh`: investigate through the harness's read-only explore subagent, keep only conclusions, capture large command output to a file and read the tail, and run the full suite exactly once (already stated in the definition of done).
Firstmate itself is already subagent-first at the fleet level, because all project work is delegated to crews.

### Layer 2 - observe

A ceiling cannot be guaranteed if firstmate cannot see where a session sits.

- **`bin/fm-context-gauge.sh <session>`** follows the `fm-crew-state.sh` pattern: determinism in bash, one token-tight line out.
  It reads native usage where the harness exposes it (Claude Code's transcript and `/context`), and otherwise falls back to a harness-agnostic proxy - reset-relevant events since the last reset, such as wakes handled, diffs read, peeks, and turns.
- **The watcher maintains a cheap per-session pressure counter** in `state/`, since it already observes every wake, and emits a new **`context-high` wake class** alongside the existing absorb classes when a session crosses a soft threshold.
- Phase 0 ships this layer alone, with no behavior change, so the whole premise is validated against real numbers before any reset machinery is built.

### Layer 3 - lossless reset

What makes the ceiling hard rather than hoped-for.

**Firstmate self-reset - the helm handoff.**
On a hard-threshold pressure signal, or opportunistically when all crews are idle or parked, firstmate:
1. flushes any volatile in-head state to durable files - a pending decision goes to the direction ledger or `capture-decision`, an in-flight judgment to a task note - so nothing important lives only in the conversation;
2. writes a bearings-grade checkpoint, which `bearings` already produces roughly eighty percent of;
3. hands off, either through the harness's `/compact` seeded with that checkpoint (manual compaction beats auto-compaction because firstmate chooses what survives), or through a genuine restart that re-runs `bin/fm-session-start.sh`.
A restart is the most lossless option and is already fully engineered as recovery, so the new work is only the trigger and the pre-reset flush.
Safety rule: never reset while holding an un-externalized decision.

**Crew self-reset - progress file and re-attach.**
A crew's durable state is its worktree, commits, and status file; what is not durable today is its working plan, which lives only in its context.
Add to the crew brief that a crew maintains a running `.fm/progress.md` in its worktree - the task decomposition, what is done, what is left, and key findings.
With commits-as-checkpoints plus that file, a crew restart becomes nearly a non-event too.
Add a spawn or recovery affordance to re-attach a fresh crew session to an existing worktree and branch with a re-brief that points at `progress.md`, so firstmate can reset a context-high crew in place rather than losing its work.

## 4. Cross-cutting

- A harness capability matrix in the `harness-adapters` skill records, per adapter: context editing available, `/compact` available, read-only subagent available, native usage read available.
- An inheritable `config/context-management` knob carries the soft and hard thresholds and the per-harness posture, defaulting to the Claude-first stack with a floor elsewhere.
- Every layer degrades gracefully: the floor of bounded tools plus reset needs only durable state, which every verified harness already has.
- Each harness fact is verified empirically and recorded like every other adapter fact, per the `harness-adapters` verification discipline.

## 5. Thresholds (starting point, tune in Phase 0)

- Soft threshold: about 120,000 tokens - emit `context-high`, prefer an opportunistic reset at the next natural boundary.
- Hard threshold: about 160,000 tokens - reset now, leaving margin below the 200,000 ceiling for the reset turn itself.
- These are defaults in `config/context-management`, revisited once Phase 0 reports real distributions.

## 6. Reuse map

The plan leans on machinery that already exists rather than inventing parallel systems.

- Recovery as a non-event: `AGENTS.md` section 4 and `bin/fm-session-start.sh` already reconstruct a full session from durable state.
- The checkpoint: the `bearings` skill and `bin/fm-bearings-snapshot.sh` already produce a "pick up where I left off" projection.
- Bounded reads: `fm-crew-state.sh`, `fm-peek.sh`, `fm-fleet-snapshot.sh`, `fm-bearings-snapshot.sh`, `gh-axi`.
- The wake classifier: `bin/fm-watch.sh` and `bin/fm-classify-lib.sh` already absorb and classify wakes, and gain one new class.
- Decision externalization: `capture-decision` and `bin/fm-direction.sh` already move durable decisions out of the conversation.
- The crew contract: `bin/fm-brief.sh` already owns the brief and gains a context-discipline section.
- Harness facts: the `harness-adapters` skill and `bin/fm-harness.sh` already own per-adapter capability.

## 7. Phasing (each phase is one shippable backlog item)

- **Phase 0 - Measure.**
  `bin/fm-context-gauge.sh`, the watcher per-session pressure counter, and the `context-high` wake class.
  No behavior change; validates the premise with real data and sets the thresholds.
  Deliverables: the gauge script and header, the counter in `state/`, the new wake class in `fm-watch.sh` and `fm-classify-lib.sh`, and tests in `tests/`.
- **Phase 1 - Reduce inflow (cheap).**
  The crew-brief context-discipline section in `bin/fm-brief.sh`, and the bounded-read audit of the primary hot loop.
  Depends on nothing; can run in parallel with Phase 0.
- **Phase 2 - Auto-compaction tuned to the ceiling.**
  Launch every claude crew (and the primary) with `CLAUDE_CODE_AUTO_COMPACT_WINDOW` / `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` set from `config/context-management`, so a claude session compacts around the ceiling natively.
  Context editing (`clear_tool_uses`) is not exposed in the Claude Code CLI, so it is deferred to any future Agent-SDK-based harness.
  Depends on Phase 0 for the ceiling value.
- **Phase 3 - Lossless reset.**
  The firstmate helm handoff (pre-reset flush plus bearings-seeded checkpoint plus restart or seeded `/compact`) and the crew progress-file and re-attach affordance, triggered by the Phase 0 gauge.
  Depends on Phase 0.
- **Phase 4 - Guarantee and tests.**
  Wire the hard-ceiling trigger end to end, finalize the capability matrix and `config/context-management`, and cover the reset paths with tests in `tests/`.
  Depends on Phases 2 and 3.

## 8. Decided at sign-off

- Full three layers, including the reset machinery, so the ceiling is self-enforcing rather than advisory.
- Claude-first: the full stack on Claude/Agent-SDK, a bounded-tools-plus-reset floor on codex, opencode, pi, and grok.
- Persisted as this proposal plus phased backlog items, shipped through the normal branch and PR gate.

## 9. Open questions for the build

- The exact native-usage read path per harness, verified empirically in Phase 0 before it is trusted.
- Whether the primary hard-threshold reset should default to restart or seeded `/compact` on Claude, decided by which reconstructs more cheaply in practice.
- The proxy formula for harnesses with no native usage read, calibrated in Phase 0 against a harness that does expose it.

## 10. As built

Shipped, in order:

- **Phase 0a** - `bin/fm-context-gauge.sh` + `bin/fm-context-lib.sh`: the deterministic one-line context read. The native token read is verified for the claude harness (last transcript `usage` total, transcript matched by recorded `cwd`); non-claude harnesses fall back to a proxy event counter.
- **Phase 1** - the crew context-discipline block in every ship and scout brief (subagent-first investigation, targeted reads, capture-large-output-to-a-file).
- **Phase 2** - the robust core. `clear_tool_uses` context editing turned out to be unavailable in the Claude Code CLI, so the CLI-native `CLAUDE_CODE_AUTO_COMPACT_WINDOW` / `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` env is injected into every claude crew launch: the harness itself now auto-compacts each claude crew around the ceiling, so a crew never exceeds it without any custom machinery. The primary is held to the same ceiling by launching it with that env (documented in the configuration reference).
- **Phase 3a** - the crew durable running-plan file (`.fm/progress.md`), so a crew that auto-compacts mid-task resumes from the file and its commits.
- **Phase 3b** - the `helm-handoff` skill: firstmate prepares its own session for a lossless reset by flushing volatile in-head state to its durable homes and refreshing the bearings checkpoint, so an auto-compaction or restart loses nothing.

Deliberately deferred (not built), because the Phase 2 finding changed their value:

- The **watcher `context-high` surfacing** (the observability half of Phase 0b) and the **Phase 4 hard-ceiling trigger wiring**. Once the harness auto-compacts every claude crew at the ceiling, enforcement is automatic, so a watcher that proactively surfaces high context for firstmate to act on is largely redundant for claude - while it is the single riskiest edit (the supervision hot loop). It stays worth doing for non-claude crews (no auto-compact) and for on-demand observability, but only behind an opt-in gate, and is left as scoped future work rather than shipped autonomously into the supervision backbone.
- The **crew re-attach affordance** (attach a fresh crew session to an existing worktree): auto-compaction plus the progress file cover the common case, so firstmate-driven crew restart is no longer on the critical path.
