# Autonomous Developer Pipeline: Architecture and Detailed Design

## 1. Overview and Core Purpose

The Autonomous Developer Pipeline automates the software delivery lifecycle from Asana task intake to deployed and verified code.
It handles requirements analysis, codebase inspection, technical planning, subtask decomposition, architectural review, parallel implementation, adversarial code review, automated deployment verification, deployed end-to-end QA, and final closeout.
The pipeline interacts with human engineers through Asana at critical decision points without generating conversational noise.
It records granular telemetry across every stage, subtask, and model session to identify time sinks and token expenditure bottlenecks.

---

## 2. Design Principles

- **P1. Atomic State Transitions.**
Every stage transition is committed using atomic write-ahead logging before updating the run state.
A crash mid-stage always leaves the run in a recoverable state with exactly one recovery action: re-enter the recorded stage.

- **P2. Zero Computational Waste While Waiting.**
When a task lacks clarity, encounters a direction conflict, or awaits human clarification, all execution slots, worktree leases, and active model contexts are immediately released.
Polling for human input operates as a lightweight, non-blocking check.

- **P3. Fresh Evaluation on Human Input.**
When human guidance is posted on an escalated task, the requirements phase re-evaluates the entire context from scratch.
This prevents stale assumptions or outdated implementation paths from persisting into planning.

- **P4. Separation of Concerns and Blind Adversarial Gates.**
Planners plan; Architects evaluate architecture; Implementers write code; Reviewers review diffs blindly without seeing implementer rationales; QA verifies deployed environments independently of implementation diffs.

- **P5. Subtask DAG and Safe Concurrency.**
Tasks touching multiple files or subsystems are decomposed into a Directed Acyclic Graph of subtasks.
Subtasks with disjoint file sets and independent contracts execute concurrently in isolated worktrees.
Dependent subtasks execute sequentially in topological order.

- **P6. Comprehensive Noise-Free Telemetry.**
Every model session, stage attempt, and subtask execution records exact wall-clock timing, prompt tokens, completion tokens, cache read/write tokens, tool call counts, and computed monetary cost.
Aggregated matrices surface token spending holes and rework hotspots across projects.

---

## 3. End-to-End Pipeline Workflow and Stages

```
                [ Asana Task in "Agent Queue" ]
                               │
                               ▼
                    ┌─────────────────────┐
                    │   1. REQUIREMENTS   │◄─────────────────────────────┐
                    │  (Reality Check)    │                              │
                    └──────────┬──────────┘                              │ Human
                               │                                         │ Input
            ┌──────────────────┼──────────────────┐                      │ Provided
            ▼                  ▼                  ▼                      │
   [ ALREADY_DONE / REJECT ] [ NEEDS_HUMAN ]   [ READY ]                 │
            │                  │                  │                      │
            ▼                  ▼                  │                      │
    (Parked / Closed)   (Release Slot)            │                      │
                        [ Post Options ] ─────────┴──────────────────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │     2. PLANNING     │◄─────────────────────────────┐
                    │  (Subtask DAG)      │                              │
                    └──────────┬──────────┘                              │
                               │                                         │
                               ▼                                         │
                    ┌─────────────────────┐                              │
                    │ 3. ARCHITECT REVIEW │                              │
                    └──────────┬──────────┘                              │
                               │                                         │
                 [ REVISE: Max 3 Rounds ]                                │
                               ├─────────────────────────────────────────┤
                               │ APPROVE WITH MINORS / APPROVE           │
                               ▼                                         │
                    ┌─────────────────────┐                              │
                    │   4. IMPLEMENT      │                              │
                    │ (Parallel / Seq)    │                              │
                    └──────────┬──────────┘                              │
                               │                                         │
                               ▼                                         │
                    ┌─────────────────────┐                              │
                    │   5. CODE REVIEW    │                              │
                    │    (Adversarial)    │                              │
                    └──────────┬──────────┘                              │
                               │                                         │
                     [ FIX: Max 3 Rounds ]                               │
                               ├─────────────────────────────────────────┤
                               │ PLAN_DEFECT (Plan Flawed)               │
                               ├─────────────────────────────────────────┘
                               │ PASS / PASS_WITH_MINORS
                               ▼
                    ┌─────────────────────┐
                    │   6. PR & DEPLOY    │
                    │    (Watch SHA)      │
                    └──────────┬──────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │  7. DEPLOYED QA     │
                    │  (Test Generation)  │
                    └──────────┬──────────┘
                               │
            ┌──────────────────┼──────────────────┐
            ▼                  ▼                  ▼
      [ FAIL_CODE ]    [ FAIL_CRITERION ]      [ PASS ]
    (Back to FIX)       (Human Escalation)        │
                                                  ▼
                                       ┌─────────────────────┐
                                       │    8. CLOSEOUT      │
                                       │ - Merge PR          │
                                       │ - Asana Summary     │
                                       │ - Re-index Graph    │
                                       │ - Flush Telemetry   │
                                       └─────────────────────┘
```

---

## 4. Stage Specifications

### Stage 1: Requirements Discovery and Reality Check (`REQUIREMENTS`)
- **Inputs:** Asana card title, description, attached comments, project direction documents, and read-only repository access.
- **Responsibilities:**
  - Ingest full ticket context and comment thread history.
  - Perform a codebase reality check to verify how the subsystem currently behaves.
  - Classify task type: `ALREADY_IMPLEMENTED`, `MINOR_DELTA`, or `NEW_FEATURE`.
  - Audit acceptance criteria clarity, edge cases, error modes, and non-functional requirements.
  - If requirements are ambiguous or critical decisions are missing, formulate clear options with trade-offs and recommendations.
  - Post structured questions to Asana, release all execution slots/worktrees, and transition to `BLOCKED_ON_HUMAN`.
  - Upon human response, restart the requirements stage from the beginning to ensure full contextual coherence.
- **Outputs:** `artifacts/requirements.json` and `artifacts/requirements.md`.

### Stage 2: Technical Planning and Subtask Decomposition (`PLAN`)
- **Inputs:** `artifacts/requirements.json`, project direction, codebase architecture.
- **Responsibilities:**
  - Formulate detailed technical architecture, exact file modifications, and interface signatures.
  - Define unit, integration, and regression test strategies.
  - Decompose large tasks into a Directed Acyclic Graph (DAG) of subtasks.
  - Determine file disjointness for each subtask and assign execution modes (`parallel` vs `sequential`).
  - Declare clear interface contracts between subtasks to prevent integration divergence.
- **Outputs:** `artifacts/plan.json` and `artifacts/plan.md`.

### Stage 3: Architect Review Gate (`ARCHITECT_REVIEW`)
- **Inputs:** `artifacts/requirements.json`, `artifacts/plan.json`, project direction, codebase graph.
- **Responsibilities:**
  - Audit plan against ten core architectural grounds: Duplication (A1), Volume (A2), Commentary (A3), Layering (A4), Direction (A5), Infrastructure/Security (A6), Blast Radius (A7), Testability (A8), Completeness (A9), and Alternatives Considered (A10).
  - Verify subtask decomposition: confirm declared parallel subtasks have strictly disjoint file sets and robust interface contracts.
  - Require a verified search evidence block before granting approval to eliminate rubber-stamping.
  - Return `APPROVE`, `APPROVE_WITH_MINORS`, `REVISE` (with actionable numbered findings, capped at 3 rounds), or `ESCALATE`.
- **Outputs:** `artifacts/plan-review-<round>.json`.

### Stage 4: Implementation Orchestration (`IMPLEMENT`)
- **Inputs:** Approved `plan.json` and individual subtask briefs.
- **Responsibilities:**
  - Dispatch independent subtasks in parallel to dedicated worktrees (`fm/<run-id>-s1`, `fm/<run-id>-s2`) up to concurrency cap.
  - Dispatch dependent subtasks sequentially once prerequisite subtask branches pass quality checks.
  - Execute local quality floor hooks on commit and push (secret scan, lint, typecheck, unit tests).
  - Require implementers to perform an independent diff self-review and test verification before signaling completion.
  - Integrate subtask branches sequentially into the unified feature branch `fm/<run-id>`.
- **Outputs:** Unified feature branch `fm/<run-id>`.

### Stage 5: Deep Adversarial Code Review (`CODE_REVIEW`)
- **Inputs:** Unified PR diff, `requirements.json`, approved `plan.json`, and architect review findings.
- **Responsibilities:**
  - Perform blind adversarial review: the reviewer is intentionally not given implementer conversational rationale.
  - Refute potential findings by constructing concrete failure scenarios (specific inputs yielding incorrect outputs).
  - Ensure all architect review requirements were implemented.
  - Return `PASS`, `PASS_WITH_MINORS`, `FIX` (capped at 3 rounds), or `PLAN_DEFECT` (routes back to planning if the architecture itself was flawed).
- **Outputs:** `artifacts/review-<round>.json`.

### Stage 6: PR Creation and Deployment Watch (`PR_OPEN`, `DEPLOY_WATCH`)
- **Inputs:** Approved feature branch `fm/<run-id>`.
- **Responsibilities:**
  - Open a GitHub pull request with linked Asana cards, architectural summary, and test verification receipts.
  - Poll GitHub Actions deployment workflows until the exact merge or preview SHA finishes deploying.
  - If deployment fails, trigger `DEPLOY_FIX` (capped at 2 attempts) to resolve deployment configuration without altering product behavior.
- **Outputs:** Deployed environment preview and `artifacts/deploy.json`.

### Stage 7: Deployed QA and Test Generation (`QA`)
- **Inputs:** Deployed environment URL, Asana card, acceptance criteria.
- **Responsibilities:**
  - Exercise acceptance criteria end-to-end against the live deployed environment.
  - Generate automated integration and end-to-end regression tests matching the exercised scenarios.
  - Package new test suites into a dedicated QA test PR.
  - Return `PASS`, `FAIL_CODE` (routes back to `FIX`), or `FAIL_CRITERION` (escalates to human if deployed behavior reveals the requirement itself was invalid).
- **Outputs:** `artifacts/qa.json` and QA test PR.

### Stage 8: Closeout and Human Communication (`CLOSEOUT`)
- **Inputs:** Final run artifacts, metrics journal, test receipts.
- **Responsibilities:**
  - Re-index the project codebase knowledge graph to reflect merged changes.
  - Post executive completion summary to Asana with PR links, deploy confirmation, QA proof, and resource metrics.
  - Release task claims and clean up temporary worktrees safely.
- **Outputs:** Final Asana story and clean run state.

---

## 5. Granular Telemetry and Metrics Engine

Every session, stage attempt, and subtask records detailed JSONL events to `runs/<run-id>/metrics.jsonl`.

### 5.1 Event Schema
```json
{
  "run_id": "checkout-idempotency-k4",
  "task_id": "checkout-idempotency-k4",
  "project": "optiroq",
  "stage": "IMPLEMENT",
  "subtask_id": "subtask-1-redis-lock",
  "session_id": "sess-9a8f2c",
  "attempt": 1,
  "round": 1,
  "model_tier": "main",
  "model_id": "claude-3-7-sonnet-20250219",
  "timestamps": {
    "started_at": "2026-08-22T14:10:00.120Z",
    "completed_at": "2026-08-22T14:15:32.450Z",
    "duration_ms": 332330
  },
  "tokens": {
    "prompt_tokens": 42150,
    "completion_tokens": 3840,
    "cache_read_tokens": 128400,
    "cache_creation_tokens": 8200,
    "total_tokens": 182590
  },
  "cost_usd": 0.3821,
  "tool_calls": {
    "read_file": 14,
    "edit_file": 6,
    "bash_command": 8,
    "grep_search": 5
  },
  "quality_hooks": {
    "lint_passed": true,
    "typecheck_passed": true,
    "unit_tests_passed": true,
    "retries_count": 0
  },
  "verdict": "SUCCESS"
}
```

### 5.2 Aggregated Analytics Matrix
The telemetry engine computes fleet-wide and project-wide diagnostics:
- **Rework Token Ratio:** Ratio of tokens spent in `FIX` and `REVISE` loops compared to initial generation.
- **Architect Revision Rate:** Frequency of plan rejection per project and component.
- **Context Overhead:** Average cache-read volume per turn to detect prompt inflation.
- **Parallel Speedup Factor:** Effective acceleration achieved by concurrent subtask worktrees.
- **Model Tier ROI:** Cost efficiency across model tiers for specific stages.

---

## 6. Architecture Comparison: Node.js (TypeScript) vs. Bash

### 6.1 Trade-off Analysis Matrix

| Dimension | Bash Implementation | Node.js (TypeScript) Implementation | Analysis and Recommendation |
| :--- | :--- | :--- | :--- |
| **Data Structures & DAGs** | String manipulation via `jq`, `awk`, subshells. High risk of parsing bugs. | Native graph structures, topological sorting, typed objects. | **Node.js**: Clean representation of subtask dependencies and file disjointness. |
| **Type Safety & Schemas** | External validation calls (`ajv-cli` or `jq` scripts). Runtime-only failures. | Compile-time checking with TypeScript and in-process `Zod` validation. | **Node.js**: Eliminates schema drift and typo-induced runtime crashes. |
| **Asynchronous I/O & REST** | Sequential `curl` calls in loops with complex retry and error handling. | Non-blocking `async`/`await`, connection pooling, native retry backoff. | **Node.js**: Handles Asana and GitHub API pagination and rate limits cleanly. |
| **Process Control & Signals** | Shell traps, background PIDs, risk of orphan child processes. | Structured child process management (`execa` / `child_process`) with abort signals. | **Node.js**: Clean timeout management, stream capture, and termination guarantees. |
| **Telemetry & Metrics** | Parsing text logs and combining files via shell pipelines. | In-memory telemetry aggregation, rolling averages, and typed JSONL writers. | **Node.js**: Real-time metric accounting without subprocess invocation overhead. |
| **System Operations & Git** | Native command execution (`git`, `tmux`, `flock`). | Subprocess execution of git and CLI commands. | **Bash slight edge**: Shell commands are direct, but Node subprocess wrappers are straightforward. |
| **Codebase Size & Maintenance** | ~32,000 lines across scripts and shell tests. | Estimated ~6,000 lines of modular, readable TypeScript. | **Node.js**: Over 70% reduction in code volume with higher testability. |

### 6.2 Decision and Architecture Division
The control plane, state machine, Asana client, DAG scheduler, and telemetry engine will be implemented in **Node.js / TypeScript**.
Low-level leaf operations that interface with the OS (git worktree creation, project quality floor hooks, and tmux process bootstrapping) remain lightweight shell scripts or child process invocations.

---

## 7. Node.js System Architecture

```
@firstmate/pipeline (TypeScript Monorepo / Package)
├── src/
│   ├── core/
│   │   ├── state-machine.ts       # Atomic transition engine & write-ahead journal
│   │   ├── dag-scheduler.ts       # Subtask dependency graph & parallel queue
│   │   ├── lease-manager.ts       # Process leases & progress watchdogs
│   │   └── types.ts               # Shared TypeScript domain models
│   ├── stages/
│   │   ├── requirements.ts        # Reality-check & Asana intake analyzer
│   │   ├── planner.ts             # Technical plan & subtask decomposition
│   │   ├── architect.ts           # 10-point architectural review gate
│   │   ├── implementer.ts         # Worktree dispatcher & slice integrator
│   │   ├── reviewer.ts            # Adversarial blind code reviewer
│   │   ├── deployer.ts            # GitHub deploy workflow SHA watcher
│   │   └── qa.ts                  # Deployed environment tester & test generator
│   ├── integrations/
│   │   ├── asana-client.ts        # Idempotent Asana REST client & outbox
│   │   ├── github-client.ts       # GitHub API / gh wrapper for PRs and CI
│   │   └── harness-adapter.ts     # Claude Code & OpenCode headless runners
│   ├── telemetry/
│   │   ├── metrics-collector.ts   # In-session token, time, and tool tracker
│   │   └── reporting-matrix.ts    # Project spending hole & heatmap generator
│   └── cli.ts                     # Main entry point (tick, status, show, doctor)
└── tests/
    ├── state-machine.test.ts      # Crash recovery, WAL, and re-entrancy tests
    ├── dag-scheduler.test.ts      # Topological sorting and disjoint checks
    ├── asana-client.test.ts       # Idempotency and outbox retry tests
    └── telemetry.test.ts          # Token accounting and cost calculation tests
```
