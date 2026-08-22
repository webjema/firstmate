# Autonomous Pipeline Deadlock Prevention: Design & Implementation Specification

**Status**: Proposal / Ready for Implementation  
**Date**: 2026-08-18  
**Scope**: Prevention of worker starvation, file-overlap dead-loops, silent unposted escalations, and cross-project starvation in the autonomous delivery pipeline (`fm-pipe`).  
**Targets**: `box/pipeline/fm-pipe-build.sh`, `box/pipeline/fm-pipe-tick.sh`, `box/pipeline/fm-pipe.sh`, `box/pipeline/fm-pipe-board.sh`, `box/pipeline/lib/common.sh`.

---

## 1. Problem Statement & Root Cause Analysis

On 2026-08-18, the autonomous delivery pipeline experienced a complete 4-worker fleet freeze where all active tasks stalled for multiple hours with zero Asana movement.

Investigation revealed a 4-point failure cascade:

```
[Automatic Table Transition to BLOCKED]
  │  (Failure 3: No outbox notification generated -> Human is never alerted in Asana)
  ▼
[Task sits in BLOCKED indefinitely]
  │  (Failure 2: run_holds_files treats BLOCKED tasks as holding active file locks)
  ▼
[Downstream tasks touching overlapping files enter SLICE]
  │  (Failure 1: slice_hold executes an active in-process `sleep 15` loop holding worker leases)
  ▼
[All 4 worker slots consumed by idling slice_hold loops]
  │  (Failure 5: Global concurrency cap blocks all projects & non-overlapping tasks)
  ▼
[COMPLETE FLEET DEADLOCK]
```

---

## 2. Architectural Design: Core Changes

### Point 1: Passive Yield at `SLICE` (Zero-Worker Waiting)
* **Goal**: A task waiting for file-overlap clearance must release its worker lease and exit immediately. It must never hold a worker slot or heartbeat while waiting.
* **Architecture**:
  - `slice_hold()` in `fm-pipe-build.sh` is transformed from a blocking in-process loop into a non-blocking gate.
  - If `overlapping_run()` returns an active run:
    1. Log the hold reason and timestamp to the run journal.
    2. Release the worker lease (`lease_drop`).
    3. Exit cleanly with status `0` / hand back to the tick without advancing stage.
  - The task remains at stage `SLICE` with `lease_state == free`.
  - In `fm-pipe-tick.sh:step_supervise()`, before relaunching a free run at `SLICE`, the tick evaluates `overlapping_run()`. If still overlapping, it stays parked without spawning a runner process. When the overlap clears, the tick launches the runner to execute `do_slice`.

---

### Point 2: Redefine `run_holds_files` (Exclude `BLOCKED` and `PARKED`)
* **Goal**: A blocked task waiting on human decision must not block downstream tasks from building or slicing.
* **Architecture**:
  - `run_holds_files()` defines whether a run is actively modifying files.
  - `BLOCKED` runs have released their worktree and runner lease; they are inert.
  - Modify `run_holds_files()` to return `1` (false) for `BLOCKED` and `PARKED` stages:
    ```bash
    run_holds_files() {
      local stage=$1
      case "$stage" in
        ''|SELECT|READINESS|PLAN|PLAN_REVIEW|SLICE|BLOCKED|PARKED) return 1 ;;
      esac
      table_is_terminal "$stage" && return 1
      return 0
    }
    ```
  - Downstream runs can proceed through `SLICE`, `IMPLEMENT`, and `CODE_REVIEW`.
  - Any real git conflicts at merge time are resolved by standard `INTEGRATE` / `MERGE` rebasing rather than speculative queue-freezing.

---

### Point 3: Mandatory Asana Outbox Escalation on All `-> BLOCKED` Transitions
* **Goal**: Every transition to `BLOCKED` must generate an Asana comment and attempt immediate delivery, regardless of whether it was triggered via CLI `escalate` or a table transition (`needs-human`, `slice-blocked`, `escalate`, `timeout`, `fail-criterion`).
* **Architecture**:
  - Hook into `do_transition()` in `fm-pipe.sh`:
    - If target stage `$to == "BLOCKED"`, check if `asana-outbox.jsonl` already received a comment for this transition attempt.
    - If not:
      1. Synthesize an escalation artifact (`artifacts/escalation-<stage>.md`) from the stage's verdict artifact (`readiness.json`, `plan-review.json`, `implement.json`, etc.) or `$note`.
      2. Queue an outbox entry via `outbox_queue "$dir" "blocked-$stage-$attempt" "$comment"`.
      3. Call `pipe_outbox_deliver "$run_id"` immediately to attempt inline posting to Asana.

---

### Point 5: Per-Project Concurrency Isolation & Fair-Share Scheduling
* **Goal**: Prevent one project from starving other projects when multiple tasks are in-flight.
* **Architecture**:
  - Introduce `FM_PIPE_MAX_IN_FLIGHT_PER_PROJECT` (default: 2, configurable in `config/pipeline.env`).
  - Update `runs_with_a_worker_for_project "$project"` in `fm-pipe-tick.sh`.
  - In `step_supervise()` and `claim_and_launch()`:
    - Prioritize projects with zero active workers before assigning second slots.
    - Enforce the per-project cap if other projects have eligible cards in `Agent queue` or unblocked runs waiting for workers.

---

## 3. Detailed Implementation Specifications

### Implementation 1: `fm-pipe-build.sh` (Passive Yield & File Hold Redefinition)

```bash
# ==============================================================================
# In box/pipeline/fm-pipe-build.sh
# ==============================================================================

# 1. Update run_holds_files to exclude BLOCKED and PARKED
run_holds_files() {
  local stage=$1
  case "$stage" in
    ''|SELECT|READINESS|PLAN|PLAN_REVIEW|SLICE|BLOCKED|PARKED) return 1 ;;
  esac
  table_is_terminal "$stage" && return 1
  return 0
}

# 2. Update slice_hold to yield immediately instead of looping
slice_hold() {
  local mine=$1 other entered now age
  other="$(overlapping_run "$mine")" || return 0

  entered="$(entered_slice_epoch)"
  now="$(pipe_epoch)"
  age=$(( now - entered ))

  if [ "$age" -ge "$FM_PIPE_HOLD_MAX_SECS" ]; then
    escalate_stage SLICE \
      "this run's file set has overlapped an in-flight run's for ${age}s, over the ${FM_PIPE_HOLD_MAX_SECS}s bound of design 16.6." \
"Holding run: $other

Two runs editing the same files do not fail while they are being written; they
fail when they are merged, as a conflict that costs a whole re-plan.

Options:
1. Let the other run finish, then re-queue this one.
2. Abandon whichever of the two matters less.
3. Re-plan this card onto a file set that does not overlap."
    return 1
  fi

  # Log hold and yield worker lease back to tick
  say "yielding at SLICE (${age}s of ${FM_PIPE_HOLD_MAX_SECS}s): file set overlaps $other - releasing worker slot"
  return 2  # Exit code 2: Yielded on overlap
}

# 3. Handle yield in do_slice
do_slice() {
  local plan base declared count i j a b hit union contract summary rc
  prepare_workdir || return 1
  tracked_files_load

  plan="$(newest_plan_json)"
  if [ -z "$plan" ]; then
    escalate_stage SLICE "there is no plan artifact in this run record to slice." \
"SLICE reads the approved plan's \`slices\` and \`fileset\`. The run reached this
stage without one, which means PLAN_REVIEW approved something that is not on
disk."
    return 1
  fi

  declared="$(plan_declared_globs "$plan")"
  if [ -n "$declared" ]; then
    slice_hold "$declared"
    rc=$?
    if [ "$rc" -eq 2 ]; then
      # Yielded: drop lease and return clean without transition
      lease_drop
      return 0
    elif [ "$rc" -ne 0 ]; then
      return 1
    fi
  fi

  # Proceed with normal slice generation...
  # [Existing slice logic continues]
}
```

---

### Implementation 2: `fm-pipe.sh` (Universal Asana Outbox Escalation)

```bash
# ==============================================================================
# In box/pipeline/fm-pipe.sh: do_transition()
# ==============================================================================

# Ensure every transition to BLOCKED queues an Asana escalation comment
if [ "$to" = "BLOCKED" ]; then
  local outbox_file="$dir/asana-outbox.jsonl"
  local last_key="blocked-$stage-$attempt"
  local already_queued=0

  if [ -f "$outbox_file" ]; then
    if grep -q "\"key\":\"$last_key\"" "$outbox_file" 2>/dev/null; then
      already_queued=1
    fi
  fi

  if [ "$already_queued" -eq 0 ]; then
    local esc_title="The pipeline stopped this run at $stage: it needs a decision before it can continue"
    local esc_body=""
    
    if [ -n "$artifact" ] && [ -f "$dir/$artifact" ]; then
      # Extract summary or reason from JSON artifact if present
      esc_body="$(jq -r '.summary // .reason // .note // empty' "$dir/$artifact" 2>/dev/null || true)"
    fi
    [ -n "$esc_body" ] || esc_body="${note:-$verdict at $stage}"

    local esc_text="The \`$stage\` stage of this run stopped with verdict \`$verdict\`.\n\n$esc_body\n\nOptions:\n1. Answer the question on the card to unblock the run.\n2. Abandon the run with \`fm-pipe.sh abandon $(basename "$dir")\`."
    local esc_file
    esc_file="$(escalation_write "$dir" "$stage" "stopped at $stage ($verdict)" "$esc_text")" || true
    
    outbox_queue "$dir" "$last_key" \
      "$(escalation_comment "$dir" "$stage" "$esc_title" "$esc_text" "${esc_file:-$artifact}")"
  fi
fi
```

---

### Implementation 3: `fm-pipe-tick.sh` (Fair-Share & Overlap-Aware Supervise)

```bash
# ==============================================================================
# In box/pipeline/fm-pipe-tick.sh: step_supervise() & claim_and_launch()
# ==============================================================================

: "${FM_PIPE_MAX_IN_FLIGHT_PER_PROJECT:=2}"

runs_with_a_worker_for_project() {
  local want_proj=$1 id n=0 p
  for id in $(run_ids); do
    [ "$(lease_state "$PIPE_RUNS_DIR/$id")" = held ] || continue
    p="$(jq -r '.project // empty' "$PIPE_RUNS_DIR/$id/run.json" 2>/dev/null || true)"
    [ "$p" = "$want_proj" ] && n=$(( n + 1 ))
  done
  printf '%s\n' "$n"
}

# In step_supervise():
step_supervise() {
  local id stage state out rc live started=0 deferred=0 proj proj_workers
  controller_acquire supervision || return 0
  live="$(runs_with_a_worker)"
  pipe_require_int "$FM_PIPE_MAX_IN_FLIGHT" "FM_PIPE_MAX_IN_FLIGHT"

  for id in $(run_ids); do
    stage="$(run_stage_of "$id" || true)"
    [ -n "$stage" ] || continue
    table_is_terminal "$stage" && continue
    case "$stage" in BLOCKED|UNBLOCK|DEPLOY_WATCH) continue ;; esac

    state="$(lease_state "$PIPE_RUNS_DIR/$id")"
    [ "$state" = free ] || continue

    # Check 1: If at SLICE, do not spawn worker if overlapping run is still in-flight
    if [ "$stage" = "SLICE" ]; then
      local declared
      declared="$(run_declared_globs "$PIPE_RUNS_DIR/$id")"
      if [ -n "$declared" ]; then
        if overlapping_run_id="$(overlapping_run_check "$id" "$declared")"; then
          trace "$id: holding at SLICE due to overlap with $overlapping_run_id - skipping worker spawn"
          continue
        fi
      fi
    fi

    # Check 2: Global concurrency cap
    if [ "$(( live + started ))" -ge "$FM_PIPE_MAX_IN_FLIGHT" ]; then
      deferred=$(( deferred + 1 ))
      continue
    fi

    # Check 3: Per-project fair-share cap
    proj="$(jq -r '.project // empty' "$PIPE_RUNS_DIR/$id/run.json" 2>/dev/null || true)"
    if [ -n "$proj" ]; then
      proj_workers="$(runs_with_a_worker_for_project "$proj")"
      if [ "$proj_workers" -ge "$FM_PIPE_MAX_IN_FLIGHT_PER_PROJECT" ] && [ "$live" -gt 0 ]; then
        trace "$id: project $proj at worker cap ($proj_workers/$FM_PIPE_MAX_IN_FLIGHT_PER_PROJECT) - deferring"
        continue
      fi
    fi

    # Launch worker
    if launch_runner_for "$id" "$stage"; then
      started=$(( started + 1 ))
    fi
  done
}
```

---

## 4. Verification & Testing Plan

1. **Test 1: Non-Blocking Yield at `SLICE`**
   - Seed two runs $R_1$ and $R_2$ modifying `packages/types/src/index.ts`.
   - Run $R_1$ into `IMPLEMENT`.
   - Run $R_2$ into `SLICE`. Verify $R_2$ yields without error, lease is `free`, exit status is `0`, and worker count remains 1.
   - Transition $R_1$ to `DONE`. Run tick. Verify $R_2$ is automatically dispatched and enters `IMPLEMENT`.

2. **Test 2: `BLOCKED` Does Not Hold Files**
   - Seed run $R_1$ at `BLOCKED` (with branch modifying `lambdas/api.ts`).
   - Run $R_2$ targeting `lambdas/api.ts` into `SLICE`.
   - Verify `run_holds_files "BLOCKED"` returns false; $R_2$ proceeds immediately through `SLICE` into `IMPLEMENT`.

3. **Test 3: Automatic Asana Outbox on `-> BLOCKED`**
   - Trigger worker verdict `needs-human` at `READINESS`.
   - Verify `asana-outbox.jsonl` contains formatted escalation comment with story metadata and option list.
   - Verify `asana-posted.jsonl` records delivery without manual `escalate` CLI invocation.

4. **Test 4: Multi-Project Fair Share**
   - Seed 4 runs in Project A and 2 runs in Project B.
   - Run tick. Verify Project A receives 2 slots and Project B receives 2 slots (rather than Project A consuming all 4).
