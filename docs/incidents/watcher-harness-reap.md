# The harness reap walks ppid descendants, so setsid never saved the watcher

2026-08-16.
Two confirmed watchers died within four minutes of each other on a healthy fleet, each one taken down with its arm, after `048f196` had shipped the two fixes that were supposed to make exactly that impossible.
This records what actually kills them, measured rather than inferred, and why the fix is where the watcher RUNS rather than what the arm does on its way out.

## What was observed

`state/.watch-arm.log`, live primary home, two occurrences:

```
2026-08-16T20:20:08Z	pid=616140	signal: TERM - watcher pid=618273 confirmed=1
2026-08-16T20:23:36Z	pid=779152	signal: TERM - watcher pid=780275 confirmed=1
```

In both, immediately after: the watcher pid is gone from `ps`, `bin/fm-wake-drain.sh` is empty, no further arm-log line for that watcher, and `bin/fm-supervision-live.sh` reports DOWN with a beacon only seconds old.
Two other arms in the same window (20:19:47Z, 20:23:20Z) exited normally and their watchers survived.
Same code, two outcomes, one variable: whether the arm was signalled or exited on its own.

It is not rare and it is not load-dependent.
Five more in the same home inside five minutes on a quiet box, same shape every time - `signal: TERM - watcher pid=N confirmed=1`, then the watcher gone, the wake queue empty, no further arm-log line, and `bin/fm-supervision-live.sh` DOWN with a beacon 5-18s old:

```
2026-08-16T21:32:52Z	pid=970034	watcher 970452
2026-08-16T21:33:28Z	pid=973755	watcher 974153
2026-08-16T21:35:24Z	pid=978599	watcher 978981
2026-08-16T21:37:06Z	pid=1002878	watcher 1003396
2026-08-16T21:37:22Z	pid=1015094	watcher 1015497
```

Both shipped defences were working as designed and neither is relevant:

- F1, `bin/fm-watch-arm.sh` `cleanup_child`, spares a confirmed watcher.
  It did: `confirmed=1` in both lines, and the arm's own log records that it took the spare path.
- F7 records the arm's death signal.
  It did: that is the line above.

So the watcher was not killed by its arm.
Something outside killed both.

## The four candidates

1. A cgroup-level reap - the hypothesis in `data/watcher-death-rootcause-h9/report.md` section 5.
2. The watcher exiting on its own through a path that writes no log line.
3. The home lock being lost rather than the process dying.
4. `setsid` present in PATH but the fallback branch taken anyway.

## The measurement

`.fm/lab/lab1.sh` and `.fm/lab/lab2.sh` (throwaway, not committed) each started several long-lived beat loops of different shapes from one Claude Code background task, then stayed alive so the task could be stopped.
Stopping the task is the reap under investigation.
Every child logged its own signal receipt, its ppid, its pgid/sid, and its cgroup.

| variant | ppid | pgid/sid | cgroup | survived the reap |
| --- | --- | --- | --- | --- |
| plain `&` child | the arm | the arm's | the arm's | no |
| `setsid` child (F2, what ships today) | **the arm** | its own | the arm's | **no** - logged an explicit TERM receipt |
| `setsid` child reparented to init | 1 | its own | the arm's | **yes** |
| tmux-hosted pane | the tmux server | its own | its own scope | **yes** |

The reap is a **ppid-descendant walk**.
`setsid` changes session and process group and does NOT change ppid, so a setsid'd watcher is still a descendant of the arm and is still signalled.
That is the whole defect: F2 defends against `kill -TERM -<pgid>`, and the harness does not do that.

Each candidate, against that evidence:

1. **Cgroup: eliminated.** The init-reparented orphan shared the arm's cgroup and survived. The agent shell running the lab shares that same `tmux-spawn-<uuid>.scope` and survived every stop.
2. **Silent self-exit: eliminated as the cause.** Genuinely silent exits do exist - `bin/fm-watch.sh:641` (singleton self-eviction) and `:338` (queue-write failure) - but the lab reproduced an explicit external SIGTERM receipt on the exact shape the live home runs.
3. **Lock loss: eliminated.** `clear_stale_recorded_watcher_lock` (`bin/fm-watch-arm.sh`) is reachable only from `--restart`, which neither occurrence used.
4. **setsid fallback: eliminated by direct `/proc` read.** Live arm 847912, its watcher 849303, `pgid=sid=849303` and `PPid: 847912`: the setsid branch ran, and left the ppid pointing at the arm exactly as the lab shows.

## The fix

Host the watcher in tmux, in the home's own detached session, where its parent is the tmux server.
`ps -o ppid= -p 254402` on this box's tmux server prints `1`: no walk that starts at a harness task shell can reach a pane it owns.

The protection is exactly that the server is not a descendant of the harness's task shell, and nothing more.
tmux daemonizes its server, so on this box the parent is init; a host that reparented daemons into the harness's own tree instead would leave hosting no safer than a plain child.
No check enforces this, deliberately: falling back to a child there would be trading a silent failure for a different silent failure, and the tmux server is already the runtime backend every crew window depends on.

A double fork would escape the same walk.
It was rejected: it produces a daemon nobody asked for - invisible, with no window to peek and nothing to reap - while tmux is already firstmate's runtime backend, the window is inspectable, and it closes when the watcher exits.

`setsid` stays as the fallback where no tmux server can be reached.
It is strictly better than a plain child and strictly worse than a pane, and an arm that refused to start a watcher at all would be a worse outage than the one this prevents.

## What this trades

**The arm's contract with its caller does not change.**
A harness still runs `bin/fm-watch-arm.sh` as its own background task and still treats the arm's completion as the wake, and the arm still exits only on information.
Only where the watcher RUNS moved, so no supervision protocol needed rewriting, and the Codex bounded-foreground checkpoint path never touches the arm at all.

**Watcher lifetime now depends on the tmux server, and it did not before.**
Kill the server and every home's watcher goes with it - where before each would have survived as an orphan.
Accepted, because tmux is already the whole runtime backend: a server restart takes every crew window with it too, so a surviving watcher would be supervising a fleet that no longer exists.
The next arm relaunches a watcher within its cycle, and `bin/fm-supervision-live.sh` reports DOWN honestly in the gap.

**The watcher window closes itself, and it has to close itself from the inside.**
By the time a watcher ends, the arm that opened its window is usually gone - that is the point of hosting it here - so nothing outside can reap it.
The launcher waits on the watcher and then kills its own window through `$TMUX_PANE`; tmux destroys the session when its last window goes.
The naive version of this does not work: `remain-on-exit on` is set globally on the box firstmate runs on, deliberately, so a crashed crew pane stays readable.
Under it a pane whose command has exited just sits there dead, and every relaunch would leave another dead window in the home's watcher session, forever.
Measured before the fix: killing a watcher left `dead=1` panes that were still there eight seconds later, with the relaunched watcher's window beside them.
The window is also set `remain-on-exit off` when it is created - scoped to that window, never the server - which covers a launcher that is killed outright and so never reaches its own cleanup.

**The standby and promote mechanism (`582bfb7`, F5) is unaffected.**
A standby parks on the incumbent ARM through the arming marker, never on the watcher, and arm lifetime is unchanged.
The owner claim makes a promoted standby strictly better informed: it adopts a surviving orphan watcher and stands by for a watcher another live arm owns, a distinction the old parent-pid proxy could no longer draw once the parent became the tmux server.

**A watcher session is named `fm-watch-<home-basename>-<checksum of FM_HOME>`, with one window named `watcher`.**
Several homes on one host each get their own session, and none of it enters the crew's flat `fm-<id>` window namespace.
