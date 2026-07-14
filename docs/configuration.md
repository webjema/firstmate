# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When the default backend is selected and compatible `tasks-axi` is on `PATH`, firstmate uses its verbs for routine backlog mutations.
Secondmate handoffs are separate and unconditional: `fm-backlog-handoff.sh` keeps only its own fleet-level validation and always delegates the item move to `tasks-axi mv`, the single owner of the backlog format.
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their home for pruning or archiving.
Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Because bootstrap requires `tasks-axi` on `PATH` on every profile, that delegation works fleet-wide, and the `config/backlog-backend=manual` knob governs firstmate's own hand-editing of its backlog, not this validated helper.
Compatible means the shared bootstrap probe accepts `tasks-axi --version` as 0.1.1 or newer, `tasks-axi update --help` exposes `--archive-body`, and `tasks-axi mv --help` exposes `[<id>...]` for the atomic multi-ID move introduced in 0.2.2 and required by handoff delegation.
That sentence is the single owner of the tasks-axi compatibility definition; every other document points here instead of restating the version gates.
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for missing-tool reporting and `TASKS_AXI: available` behavior.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress `TASKS_AXI: available`, not missing-tool reporting.
Absent or `tasks-axi` selects the default tasks-axi backend.
The file format is unchanged in both modes; tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.

## Runtime backend

tmux is firstmate's only runtime backend: the session provider where every task window is created, captured, sent to, watched, and killed (see [`docs/tmux-backend.md`](tmux-backend.md)).
There is nothing to select and no fallback - `bin/fm-backend.sh` resolves `tmux` unconditionally, and treehouse remains the worktree provider.
Task meta records no `backend=` line; an absent `backend=` means `tmux`.
Task selectors for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit endpoint escape hatch.
Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that themselves start with `fm-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded `window=` target, and a matching explicit target can still recover the recorded metadata when it names the same endpoint.
Only metadata-routed task selectors carry secondmate-marker and Codex-harness context; explicit endpoint escape hatches do not.
These sentences are the single owner of the task-selector vocabulary; other documents point here instead of restating the resolution order.
`fm-teardown.sh <id>` takes a task id directly and uses the same recorded target field after loading `state/<id>.meta`.
The session-start secondmate liveness sweep uses the deeper `fm_backend_agent_alive` probe, which classifies a tmux secondmate endpoint as `alive`, `dead`, or `unknown`.

## Away-mode supervisor backend (FM_SUPERVISOR_BACKEND / FM_SUPERVISOR_TARGET)

The `/afk` sub-supervisor injects escalation digests into firstmate's own pane.
It supports only `tmux` supervisor panes.
Set `FM_SUPERVISOR_BACKEND=tmux` and `FM_SUPERVISOR_TARGET=<target>` to override both axes explicitly.
Without overrides, backend detection resolves `tmux`, and target detection uses `FM_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then the legacy `firstmate:0` fallback with a warning.
Selecting any other supervisor backend refuses at daemon startup instead of trying tmux injection primitives against a non-tmux pane.

## Away-mode wedge alarm channels (config/wedge-alarm)

When away-mode injection wedges past `FM_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured active alert that can reach the captain even when the pane and its status-line are unreadable.
`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.
Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on macOS: the alarm exists precisely so a wedged away-mode primary is never silent, and it fires at most once per max-defer window after a genuine wedge.
A missing or failing channel logs and falls through to the next, never crashing the daemon.
See [`wedge-alarm.md`](wedge-alarm.md) for the channel reference and macOS verification evidence, and [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Captain preferences (data/captain.md)

Personal preferences for one captain's fleet live locally in `data/captain.md`; it is gitignored and printed in the session-start context digest after `data/projects.md` and optional `data/secondmates.md`.
Before changing it, inspect the current file and rewrite or prune the matching bullet in place; add a new bullet only for a genuinely new durable preference.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed right after `data/captain.md` in the session-start context digest.
The file is created lazily on first learning and follows the same dated, evidence-backed, curated style as `data/captain.md`: inspect the current file first, then rewrite or prune stale entries instead of appending forever.

## Secondmate routes (data/secondmates.md)

Persistent secondmate routes live locally in `data/secondmates.md`.
Each line records the secondmate id, charter summary, absolute home path, natural-language scope, project clone list, and added date; `fm-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
The main first mate routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `fm-home-seed.sh <id> - {<project>...|--no-projects}` to lease a fresh firstmate worktree for the secondmate home.
Use the deliberate `--no-projects` signal only for a firstmate-repo domain that needs no separate project clones.
It cannot be combined with a project list, and omitting both still fails loudly.
A project-less seed requires no existing project clones or `data/projects.md` entries in the home, so it refuses a populated-home conversion without changing that home.
A preexisting project-bearing charter is also refused until it is re-scaffolded with `--no-projects` or removed.
The lease is held under the secondmate id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `treehouse return` cannot release the lease; plain-clone homes with no treehouse pool slot are removed directly.
Secondmate routes cover `PR` projects; `local-only` projects remain main-firstmate work.
After creating a secondmate, move existing main-backlog queued items that you have judged in-scope with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`; it is idempotent and refuses In flight, Done, or non-secondmate homes.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.
Each seed writes an `.fm-secondmate-home` identity marker at the home root.
The tracked root `.gitignore` ignores that marker, so validation can read it without making a freshly seeded home appear dirty to porcelain-based safety checks.
This does not relax protection for any other untracked file.
An existing linked-worktree home that predates this rule advances through its marker-only state during its next bootstrap or spawn local sync, after which Git ignores the marker normally.
A standalone-clone home cannot receive a primary-local commit through that no-fetch sync, so it receives the rule through `/updatefirstmate`'s origin refresh instead.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, most scripts use the repo root as the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`bin/fm-send.sh` is intentionally stricter than that general fallback: it requires `FM_HOME` to be set before resolving a target, so operator steers cannot silently resolve against the wrong home.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.

## Harness support

claude, codex, opencode, pi, and grok are all empirically verified; new harnesses get verified through a supervised trial task before joining the set.
The verified adapter knowledge - busy signatures, interrupt and exit commands, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
Launch mechanics, including the verified command templates, live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
Primary-session turn-end guard integrations for verified harnesses are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](turnend-guard.md).
Primary-session watcher wake protocols are rendered at session start by [`bin/fm-supervision-instructions.sh`](../bin/fm-supervision-instructions.sh) from [`docs/supervision-protocols/`](supervision-protocols/).
Claude and Grok use background-notify cycles, Codex uses bounded foreground checkpoints, Pi uses its two tracked primary extensions, and OpenCode uses its TUI plugin.
`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.
`config/secondmate-harness` is a separate local, gitignored file containing the adapter the primary uses to launch secondmate agents, optionally followed by model and effort tokens on the same line.
The first non-empty, non-comment line is parsed as `<harness> [<model>] [<effort>]`.
A bare `<harness>` preserves the previous behavior: harness only, with no model or effort launch flag.
When the harness token is absent or `default`, secondmate launch falls back through `config/crew-harness` and then the primary's own harness, and no model or effort is read from that file.
`fm-harness.sh secondmate-model` and `fm-harness.sh secondmate-effort` expose only the optional tokens from `config/secondmate-harness`; `config/crew-harness` remains a bare adapter-name file.
An explicit harness argument to `fm-spawn.sh` still overrides either config file for that spawn only.
An explicit `--model` or `--effort` overrides the matching token from `config/secondmate-harness`; an explicit harness or raw launch command starts with clean model and effort defaults unless those flags are also passed.
The primary propagates `config/crew-harness` and `config/backlog-backend` into secondmate homes at secondmate spawn, during the locked session-start bootstrap secondmate sweep, and during explicit `bin/fm-config-push.sh` runs, so a secondmate's own crewmates and backlog backend use the primary values.
`config/secondmate-harness` is not inherited because secondmates do not launch secondmates.
For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Pi secondmate launches, `fm-spawn.sh` starts Pi with `-e` pointed at the secondmate home's own tracked `.pi/extensions/fm-primary-pi-watch.ts` and `.pi/extensions/fm-primary-turnend-guard.ts`, both already present from the secondmate home's git worktree.

## Toolchain

On session start the first mate detects what its required toolchain is missing or too old and lists each problem with an exact install command.
It installs those tools only after you say go.
Required tools come in two parts: a universal toolchain every home needs, and the backend delta owned in code by `fm_backend_required_tools` in `bin/fm-backend.sh`.
The universal toolchain is node, git, gh with GitHub auth via `gh auth login`, gh-axi, chrome-devtools-axi, lavish-axi, and compatible tasks-axi per "Backlog backend" above.
This section is the single owner of that universal toolchain list; the backend guide's prerequisites point here and add only backend-specific tools.
In that list, gh-axi, chrome-devtools-axi, and lavish-axi cover GitHub, browser, and rich-review operations, and tasks-axi backs backlog mutations.
The backend delta is `tmux` itself plus the `treehouse` worktree provider, and the `treehouse` durable-lease upgrade check runs against the installed binary.
`tasks-axi` is a required bootstrap tool, the same class as `lavish-axi`.
An absent or incompatible `tasks-axi` reports `MISSING: tasks-axi (install: npm install -g tasks-axi)`; when `config/backlog-backend` is not `manual` and compatible `tasks-axi` is on `PATH`, bootstrap also prints `TASKS_AXI: available` and firstmate uses its verbs for routine backlog mutations, otherwise it hand-edits `data/backlog.md` until installation is approved and completed.
Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.
The locked session-start bootstrap step also runs a best-effort project clone refresh through `fm-fleet-sync.sh`.
It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
Normal completed runs keep local-only and no-origin skips silent.
If bootstrap kills a timed-out refresh, it replays any completed `fm-fleet-sync.sh` output before the aggregate timeout skip so no finished result is lost.
A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `fm-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `fm-teardown.sh` `index.lock` recovery.
It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.
The locked session-start bootstrap step also runs the guarded local secondmate sync for recorded live secondmate homes, then propagates declared inheritable local config into each validated live home.
It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable sync reason or config inheritance failed, and `NUDGE_SECONDMATES:` only when a running home advanced and its instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed.
`NUDGE_SECONDMATES:` lists stable `fm-<id>` task selectors; the `bootstrap-diagnostics` skill owns the send procedure.
The same bootstrap run also emits `SECONDMATE_LIVENESS:` for live secondmate endpoints: `already-live` and `respawned` are handled states, while `skipped` or `respawn failed` means the secondmate still needs attention.
For a mid-session inherited config edit where tracked-file sync and reread nudges are not needed, run `bin/fm-config-push.sh`.
It uses the same live secondmate discovery and propagation helper as bootstrap, prints each live home's `crew-harness` and `backlog-backend` result as `pushed`, `unchanged`, `skipped`, or `error`, and exits non-zero only for real propagation errors.
That live discovery starts from `state/*.meta` records with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home for most scripts, unset means this repo root; fm-send requires it explicitly
FM_ROOT_OVERRIDE=        # override firstmate repo root and tangle-guard target; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_SESSION_START_STATUS_TAIL=5   # state/*.status lines printed per task in the session-start digest
FM_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
FM_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; fm-send.sh overrides it to name the requested message specifically
FM_SPAWN_WORKTREE_TIMEOUT=900   # absolute ceiling, seconds, on waiting for `treehouse get` to hand over a worktree; only reached while the pane is visibly still working (a measured cold optiroq install is 137s)
FM_SPAWN_WORKTREE_STALL=300     # seconds a busy-but-silent provisioning pane may produce nothing before it is called stuck; 0 disables
FM_SPAWN_WORKTREE_SETTLE=5      # seconds before an IDLE provisioning pane may be believed at all: for the first ~35ms after send-keys the shell has not consumed the command, so a healthy pane looks exactly like one whose command exited
FM_SPAWN_WORKTREE_IDLE_CONFIRM=3  # consecutive idle probes (after the settle) required before a pane is called failed
FM_POOL_WARM=1                  # 0 disables preventive pool warming entirely (bin/fm-pool-warm.sh, triggered by the watcher on the FM_CHECK_INTERVAL cadence)
FM_POOL_WARM_TIMEOUT=1800       # ceiling on ONE warm, seconds; a hung install must never hold the pool lock and its treehouse lease forever (13x the measured 137s cold install)
FM_POOL_DISK_BUDGET_GB=20       # per-project-pool disk ceiling; warming STOPS and reports rather than filling the disk. Also settable per home in config/pool-disk-budget-gb. Sized by project, not slot count: optiroq is ~2.8 GB/slot, firstmate ~6 MB/slot
FM_POOL_DISK_BUDGET_KB=         # internal/test override of the above in KB, so the budget can be exercised without staging 20 GB
FM_TREEHOUSE_ROOT=~/.treehouse  # treehouse's pool root; also where the POOL-scoped warm lock lives, so secondmate homes sharing a pool contend for one lock
FM_POLL=15              # seconds between watcher poll cycles
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_CHECK_INTERVAL=300   # seconds between slow checks (e.g. merge polls)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by working/paused watcher triage
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_GUARD_GRACE=300      # seconds before guard warnings, arm health checks, and the primary turn-end guard treat a watcher beacon as stale
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED
FM_ARM_ATTACH_POLL=0.5  # seconds between checks while fm-watch-arm is attached to an existing healthy watcher cycle
FM_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary watcher plugin waits for an arm attempt to report started, healthy, wake, or failure
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:'   # OPT-IN whole-line regex; UNSET (the default), a status line is captain-relevant only when its LEADING VERB is done/needs-decision/blocked/failed, so prose in a working: note never escalates
FM_CLASSIFY_PAUSED_VERB=paused     # leading status verb for a declared external wait; not captain-relevant, and distinct from blocked
FM_WT_PROBE=1                      # 0 disables the worktree-activity probe entirely (turn-end bodies and the watcher's per-poll work evidence)
FM_WT_PROBE_MAX_FILES=20000        # tracked-file cap above which the probe skips its modified-file leg and reports dirty=? honestly
FM_WT_FRESH_SECS=120               # a worktree that moved this recently counts as still-moving work, so the spinning check does not fire on it
FM_WT_STAT_BATCH=200               # modified-file paths per stat invocation in the worktree probe (forks, not files, are the cost)
FM_WT_STILL_SECS=1800              # a LIVE pane whose worktree has not moved this long surfaces once as class=spinning; 0 disables
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane escalates; stale panes whose crew is not provably working surface immediately unless they declare the pause verb
FM_PAUSE_RESURFACE_SECS=3600       # seconds before an idle declared external wait re-surfaces for a recheck in the watcher or away-mode daemon
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before fm-teardown.sh treats a leftover worktree git index.lock as provably stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds fm-teardown.sh waits before each retry after that signature
FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after fm-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds fm-fleet-sync.sh waits before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before fm-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
FM_BUSY_REGEX='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'   # busy-pane signatures, shared by the watcher, fm-crew-state's pane fallback, and the tmux helper
FM_COMPOSER_IDLE_RE=    # optional empty-composer regex, applied after ghost and border stripping
FM_COMPOSER_GHOST_LUMA_MAX=128   # max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless. Assumes a dark terminal theme (bin/fm-composer-lib.sh's fm_composer_strip_ghost)
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between fm-send submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful text submit; 0 disables
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_BACKEND=             # optional supervisor pane backend override; tmux only, otherwise detects $TMUX_PANE before the tmux fallback
FM_SUPERVISOR_TARGET=              # optional supervisor pane target override; a tmux target, otherwise auto-detected
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_WEDGE_ALARM_CHANNEL=            # override config/wedge-alarm with one active-alert directive for the wedge alarm; off|auto|osascript|command:<cmd>; absent = auto (macOS -> an OS notification)
FM_WEDGE_ALARM_EXEC=              # notifier seam: route every channel (osascript, command:) through this command as `<cmd> <channel> <summary>`; "discard" fires nothing; unset in production; the daemon defaults it to "discard" when sourced so no test posts a real notification (docs/wedge-alarm.md)
FM_WEDGE_ALARM_TIMEOUT_SECS=10    # maximum seconds for each osascript, override, or command: notifier before its watchdog terminates it and continues to the next channel; invalid or zero values use 10
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
```

`fm-teardown.sh` retries only Git's `Unable to create '...index.lock': File exists` return failure up to `FM_TREEHOUSE_RETURN_LOCK_RETRIES` times.
`FM_TREEHOUSE_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an unset, blank, or invalid value uses the default of 3.
`FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, and a blank fallback uses the 1-second default.
An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`fm-fleet-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).
A live lock, a missing `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards fleet-sync stderr and relays only stdout - still surfaces it.
The shared staleness proof lives in `bin/fm-lock-lib.sh`, which both `fm-teardown.sh` and `fm-fleet-sync.sh` use.
