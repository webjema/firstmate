# Incident: the watcher arm notified firstmate ~80 times for one wake

Date: 2026-07-31.
Home: `/home/webjema/tools/firstmate` (primary), Claude Code primary harness.
Transcript: `~/.claude/projects/-home-webjema-tools-firstmate/9746b898-b28f-4118-8a2e-3f174f2d63f6.jsonl`.
Scripts at fault: `bin/fm-watch-arm.sh`, with `bin/fm-watch.sh` as an amplifier.

## Symptom

The session looped on information-free turns every 3 to 9 seconds, indefinitely, with no crew doing anything:

```
Background command "Re-arm supervision watcher" was stopped
  -> firstmate re-arms
watcher: attached to live watcher pid=... (beacon 2s)
  -> "Re-armed."
Background command "Re-arm supervision watcher" was stopped
  -> ...
```

Two of those turns cost roughly 380k cached input tokens each and produced nothing.
The captain also saw the turn-end guard fire on turns where a re-arm had in fact just been started:

```
TURN WOULD END BLIND - SUPERVISION IS OFF
2 task(s) in flight, but no live watcher holds this home lock (last beat: 1s ago)
```

## Measured

`docs/incidents/` is evidence, so these are the numbers as counted, with the script that counts them.
Run `python3 storm-evidence.py <transcript.jsonl>` where the script is the one reproduced at the end of this file:

```
distinct background tasks killed by the harness: 81
assistant turns that launched an arm: 280
   78  Background command \"Re-arm supervision watcher\" was stopped
   44  Background command \"Re-arm the watcher\" was stopped
   20  Background command \"Arm the watcher\" was stopped
largest kill burst: 10 tasks in 232s  (2026-07-31T07:55:27.231Z -> 2026-07-31T07:59:19.360Z)
arm launches 07:40-07:59Z: 14, median gap 13.1s (min 6.5s)
```

On the same transcript, `grep -c '<status>completed</status>'` returns 578 and `grep -c '<status>killed</status>'` returns 162 (each killed record appears twice, hence 81 distinct tasks).
Only ONE arm process was ever actually alive on the box while those 81 tasks existed: the rest were harness task rows attached to arms that had already exited or that were sitting in `attach_and_wait`.

## Notification-status semantics, established by probe

The distinction mattered because the loop was blamed on the Stop hook killing background tasks, and it is not what `killed` means.
Probed on this box on 2026-07-31 by launching background Bash tasks that exit in a controlled way, then reading the resulting `<task-notification>`:

| What the task did | What the harness reported |
| --- | --- |
| `exit 1` | `completed`, "failed with exit code 1" |
| killed with `SIGTERM` | `completed`, "exit code 143" |
| killed with `SIGKILL` | `completed`, "exit code 137" |
| reclaimed by the harness | `<status>killed</status>`, "was stopped" |

So "was stopped" is never a signal, never an exit code, and never the Stop hook.
It is the harness reclaiming a background task row it is no longer prepared to keep, and every reclamation re-invokes the model exactly like a real wake.

## Ruled out, with the check that ruled it out

- The afk daemon: `state/.afk` absent, no daemon pid file, no daemon in `ps`.
- A cross-home lock fight with the `firstmate2` secondmate: its watcher holds its own home lock, and the primary's `state/.watch.lock` recorded the primary's own path throughout.
- cron or systemd: no unit or crontab entry references `fm-watch`.
- The Stop hook killing tasks: see the probe table above; a Stop hook cannot produce `killed`.
- The OOM killer: no `Killed process` entries in the kernel log for the window.
- The harness routinely reclaiming background tasks: a control probe task lived 22 minutes across several turn ends untouched.
- Process-group kill in `bin/fm-bootstrap.sh`: its `kill -- -$pid` is scoped to the job it started under its own `set -m`.

## Root cause

`bin/fm-watch-arm.sh` treated ANY end of its watcher as news.

1. It exited whenever its watcher child exited, whether or not that watcher had a wake reason to deliver.
   On a notify-on-exit harness the arm's exit IS the wake, so a watcher that died with nothing to say still cost a full model turn.
2. `attach_and_wait()` kept every DUPLICATE arm alive on the SAME cycle.
   Firstmate answers a wake by arming again, so each wake added another live task attached to the one live cycle, and each of those tasks would in turn exit - and wake firstmate - when that cycle ended.

Those two together are multiplicative, not additive: one wake produced N notifications, firstmate answered each with another arm, and the task pool grew monotonically to 81.
The harness then began reclaiming the oldest rows, every reclamation read as another wake, and the loop became self-sustaining with no watcher event behind it at all.

The amplifier was in `bin/fm-watch.sh`: eleven `fm_wake_append ... || exit 1` sites exited SILENTLY when the durable queue could not be written.
The arm saw a bare non-zero exit with no reason line, reported it as a wake anyway, and in `handle_paused_stale()` the throttle marker is only written after a SUCCESSFUL append - so the same wake stayed permanently due and fired again on the next poll.

The `TURN WOULD END BLIND` banner was a symptom of the same design, not a separate bug.
Both guards decided "is a re-arm in flight" from the MTIME of `state/.watch.arming`, which is only valid while an arm is a short-lived startup handoff.

## Fix

The contract is now stated in `bin/fm-watch-arm.sh`'s header and enforced there:

- The arm exits ONLY on information: a watcher wake reason, wake records left in the durable queue, or one bounded `FAILED`.
- A watcher that ends with nothing to report is relaunched IN PLACE, with exponential backoff (`FM_ARM_BACKOFF_MAX`) and a churn budget (`FM_ARM_RELAUNCH_MAX` quiet exits inside `FM_ARM_CHURN_WINDOW`), and the arm stays live.
- Churn is recorded in `state/.watch-arm.log` (`FM_ARM_LOG_MAX` lines) so a bounded failure can be investigated after the fact instead of re-run to reproduce.
- One arm per home: a second arm reports `already armed pid=<pid>` and exits instead of attaching to a live cycle, so a wake can never fan out into N notifications.
- `--restart` identifies this home's incumbent arm BEFORE claiming the marker, then stops the arm first and the watcher second; a surviving arm would otherwise relaunch the watcher the restart just stopped.
- `bin/fm-watch.sh`'s failed-enqueue sites now print an explicit `heartbeat:` reason naming the unwritable queue instead of exiting silently.
- Both guards ask `fm_arm_in_flight` (`bin/fm-wake-lib.sh`), which verifies a live, identity-matched arm for this home and this arm path, and falls back to the bounded `FM_ARMING_GRACE` mtime window only for an unverifiable orphan marker.

`docs/turnend-guard.md` owns the guard tolerance and `docs/supervision-protocols/claude.md` owns what each arm status line means for the agent.

## Regression coverage

`tests/fm-watch-arm-supervision.test.sh` runs a real arm over a scripted watcher and asserts the whole contract: quiet death relaunches without exiting, a wake reason still exits with the reason verbatim, queued records still exit, the churn budget ends as ONE `FAILED`, a second arm stands down without starting a second watcher, `--restart` stops the incumbent arm, and `fm_arm_in_flight` accepts a live arm with an ancient marker while expiring a dead one's.
Writing that file found the `--restart` ordering defect above, which the storm had hidden.

## Recurrence, 2026-07-31: the arming marker had no owner

The fix above landed as PR #50 (squashed to `main` as `78c8277`) and the storm came back, quieter: `Background command "Re-arm watcher (confirmed down)" was stopped` every 15-20s, interleaved with `TURN WOULD END BLIND - SUPERVISION IS OFF`.

Measured in the primary home, running `78c8277`:

- Two arms alive at the same instant, pids `1890014` and `1909172`, which the one-arm-per-home rule is supposed to make impossible.
- `state/.watch-arm.log`: 12 exits over two hours, every one `exit: watcher wake reason propagated`, arriving in PAIRS 45-60s apart - two arms ending on the same cycle.

Root cause, in the shipped fix itself.
`bin/fm-watch-arm.sh` wrote `state/.watch.arming` exactly once at startup and removed it with an UNCONDITIONAL `trap 'rm -f "$ARMING"' EXIT`, so any short-lived arm deleted the marker belonging to a different, still-live arm.
Because the marker was never rewritten, one foreign deletion made a working arm invisible for the rest of its life.
Both consequences follow directly: the startup dedupe found no marker and let a duplicate through (the fan-out, back again), and `fm_arm_in_flight` answered false while an arm was genuinely supervising (the blind-turn banner).

A second, independent path let duplicates through even with the marker working: `run_cycle`'s adopt branch attached to any healthy watcher, and a duplicate that slipped past the startup check reached it before forking anything.

Fix:

- The EXIT trap releases the marker only when it still names THIS arm; an arm hands the marker to the live peer it stands down for rather than deleting it.
- A live arm re-takes the marker whenever it is missing or names a dead arm, so a foreign deletion self-heals within about a second instead of lasting the whole cycle.
- The arm polls its child instead of blocking in `wait`, because the self-heal has to run where the arm spends nearly all of its life.
  It naps by backgrounding `sleep` and `wait`ing on it: bash defers a trap until the running FOREGROUND command finishes, and a plain `sleep 1` here delayed the arm's own TERM handler by up to a second, which was enough to break `--restart`.
- Both adopt paths - the one before forking and the one after losing the singleton race - now ask `peer_arm_of_watcher` whether the watcher already has an arm behind it, and stand down if so.
  A watcher's PARENT is its arm, which is the one signal the marker cannot give: a duplicate that started while the marker was missing has by then claimed the marker naming itself.
  An ORPHAN watcher with no live arm is still adopted, which is the case attaching exists for.

Three cases in `tests/fm-watch-arm-supervision.test.sh` cover it: an exiting arm leaves a live peer's marker intact, a live arm re-takes a marker deleted underneath it, and a second arm stands down even when the marker was missing at the instant it started.

## Reproducing the measurements

```python
# storm-evidence.py
import json, re, sys, datetime
from collections import Counter, OrderedDict

path = sys.argv[1]
ts = lambda t: datetime.datetime.fromisoformat(t.replace('Z', '+00:00'))
killed, summaries, arm_turns = OrderedDict(), Counter(), []
for line in open(path, encoding='utf-8', errors='replace'):
    if '<status>killed</status>' in line:
        for tid in re.findall(r'<task-id>([^<]+)</task-id>', line):
            killed.setdefault(tid, json.loads(line).get('timestamp', ''))
        m = re.search(r'<summary>(.*?)</summary>', line, re.S)
        if m:
            summaries[m.group(1).strip()] += 1
    if '"type": "assistant"' in line.replace('":"', '": "') and 'fm-watch-arm' in line:
        arm_turns.append(json.loads(line).get('timestamp', ''))

print('distinct background tasks killed by the harness:', len(killed))
print('assistant turns that launched an arm:', len(arm_turns))
for text, n in summaries.most_common(3):
    print(f'  {n:3d}  {text}')
items = list(killed.items())
burst, best = [items[0]], []
for i in range(1, len(items)):
    if (ts(items[i][1]) - ts(items[i - 1][1])).total_seconds() <= 120:
        burst.append(items[i])
    else:
        best = max(best, burst, key=len)
        burst = [items[i]]
best = max(best, burst, key=len)
span = (ts(best[-1][1]) - ts(best[0][1])).total_seconds()
print(f'largest kill burst: {len(best)} tasks in {span:.0f}s  ({best[0][1]} -> {best[-1][1]})')
window = [t for t in arm_turns if t.startswith('2026-07-31T07:4') or t.startswith('2026-07-31T07:5')]
gaps = sorted((ts(window[i + 1]) - ts(window[i])).total_seconds() for i in range(len(window) - 1))
print(f'arm launches 07:40-07:59Z: {len(window)}, median gap {gaps[len(gaps) // 2]:.1f}s (min {gaps[0]:.1f}s)')
```
