# Incident: the watcher arm notified firstmate ~80 times for one wake

Date: 2026-07-31.
Home: `/home/webjema/tools/firstmate` (primary), Claude Code primary harness.
Transcript: `~/.claude/projects/-home-webjema-tools-firstmate/9746b898-b28f-4118-8a2e-3f174f2d63f6.jsonl`.
Scripts at fault: `bin/fm-watch-arm.sh`, with `bin/fm-watch.sh` as an amplifier.

This incident is not closed.
It has recurred twice: 2026-07-31 (the arming marker had no owner) and 2026-08-12 (the one-arm-per-home fix's own stand-down exit).
Read the Fix section below together with both recurrences, because a line in that fix is what caused the second one.

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
  **This line is what caused the 2026-08-12 recurrence below.**
  It is left here as written, because the sentence and its consequence are the point.
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
  A watcher's PARENT was its arm, which is the one signal the marker cannot give: a duplicate that started while the marker was missing has by then claimed the marker naming itself.
  That parent signal is gone since the watcher moved into tmux ([watcher-harness-reap.md](watcher-harness-reap.md)), and `state/.watch.owner-arm` carries the same answer explicitly; the rule below is unchanged.
  An ORPHAN watcher with no live arm is still adopted, which is the case attaching exists for.

Three cases in `tests/fm-watch-arm-supervision.test.sh` cover it: an exiting arm leaves a live peer's marker intact, a live arm re-takes a marker deleted underneath it, and a second arm refuses to duplicate even when the marker was missing at the instant it started.
The 2026-08-12 recurrence below changed what "refuses to duplicate" means - standing by rather than standing down - so those cases now assert the standby behaviour.

## Recurrence, 2026-08-12: the fan-out fix's own stand-down exit

The captain saw a terminal filling every ~15 seconds with `Background command "Re-arm supervision" completed (exit code 0)`, with supervision genuinely healthy the whole time.

Measured in the primary home before anything was changed - four consecutive background arms, read off their own output files, each exiting within seconds:

```
watcher: already armed pid=3388225 (watcher pid=3388241, beacon 13s)
watcher: already armed pid=3388225 (watcher pid=3388241, beacon 14s)
watcher: already armed pid=3388225 (watcher pid=3388241, beacon 10s)
watcher: already armed pid=3388225 (watcher pid=3388241, beacon  8s)
```

One arm (`3388225`) owned supervision and held a healthy watcher (`3388241`) throughout.
Every additional arm exited at once with a line that is not news.

Root cause: **the `One arm per home` line in the Fix section above**.
That line and the root-cause line above it cannot both be safe on the same harness, and this document stated both:

- Root cause 1: "On a notify-on-exit harness the arm's exit IS the wake, so a watcher that died with nothing to say still cost a full model turn."
- Fix: "a second arm reports `already armed pid=<pid>` and **exits** instead of attaching to a live cycle".

The fan-out fix closed the duplicate's slow door and opened a faster one.
An immediate exit is an immediate wake; firstmate answers a wake by arming; that arm exits at once too.
The result is tighter than the original storm rather than absent - a duplicate that stood down at once still cost the exact turn it stood down to save.
`bin/fm-watch-arm.sh`'s own header stated the invariant the shipped behaviour broke: "this script exits ONLY when it has something firstmate must act on."

The operator half mattered as much as the script.
`docs/supervision-protocols/claude.md` already said "do NOT start another one", and the loop still happened with a firstmate following it exactly: the protocol never said what a non-news arm COMPLETION means, so a completed background task read as "supervision ended" and the only listed repair was to arm.

Fix:

- A duplicate arm no longer exits.
  It becomes a silent STANDBY: it starts no watcher, attaches to no cycle, and parks on the INCUMBENT ARM's liveness rather than on that arm's watcher cycle.
  Parking on the arm rather than the cycle is what prevents the fan-out; not exiting is what prevents the turn spent on silence.
  Both are required, and neither substitutes for the other.
- When the arm it parked on is gone, the standby takes the arming marker and supervises in its place, so supervision survives the handover and `bin/fm-supervision-live.sh` keeps answering `live` across it.
  Promotion IS `assert_arming_marker`'s existing rule - take a marker that is missing or names a dead arm, leave a live peer's alone - so "the incumbent is gone" and "this arm owns supervision" cannot disagree.
  A settle re-read after taking the marker resolves two standbys promoting at the same instant: the second write sticks, the loser parks again.
- Steady state is two live arms, one owner and one hot spare: the owner exits on a real wake, the spare promotes into its place, and firstmate's next arm becomes the new spare.
- The status line is now `watcher: standby - supervision held by arm pid=<pid>`, named for what the task is doing rather than for what it found.
- `docs/supervision-protocols/claude.md` and `.../grok.md` now state the operator rule in those words: an arm task that ENDS without a wake line is not a wake and not the end of supervision - verify with `bin/fm-supervision-live.sh` and do NOT arm again; arm again only when it answers `watcher: DOWN`.

`bin/fm-supervision-live.sh` remains the only liveness predicate; nothing here added a second one.

Three cases in `tests/fm-watch-arm-supervision.test.sh` cover it, and all three fail against the pre-change script:
`test_second_arm_stands_by_instead_of_exiting` (the reproduction: the duplicate must still be alive well past the point where the old one had notified),
`test_standby_takes_over_when_the_incumbent_arm_ends`,
and `test_second_arm_stands_by_even_when_the_marker_was_missing`.
`test_exiting_arm_leaves_a_live_peers_marker_alone`, carried over from the 2026-07-31 recurrence, was reworked onto the standby and fails against the pre-change script too.

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
