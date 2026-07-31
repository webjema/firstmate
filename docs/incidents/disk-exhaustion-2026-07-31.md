# Incident: the box reached 94% full with 55G of reclaimable garbage on it

Date: 2026-07-31.
Host: Linux 6.17.0-1019-aws, single 154G root filesystem, `/tmp` disk-backed (not tmpfs, so a reboot does not clear it).
Home: `/home/webjema/tools/firstmate` (primary), Claude Code primary harness.
Scripts at fault: none, individually.
`bin/fm-scratch-reap.sh` and the `treehouse prune --global --yes` call in `bin/fm-bootstrap.sh` both behaved exactly as designed.
The defect is in when they are allowed to run and what nothing owns.

## Symptom

```
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/root       154G  145G  9.4G  94% /
```

Work was still possible, but a single `npm ci` across a couple of worktrees would have exhausted the disk.

## Measured

Sizes are `du -sx` in KiB, converted, taken before any cleanup.

| Path | Size | Owned by a janitor? |
| --- | --- | --- |
| `~/.treehouse/optiroq-80b6c6/` | 46.5G | yes, and correctly skipped: live fleet, work in progress |
| `~/.treehouse/optiroq-dev-9ae0cf/` | 32.4G | nominally yes, skipped in full - see below |
| `/tmp/claude-1001/` | 22.6G | yes, but the sweep had not run in days |
| `~/.npm-cache-shared/_cacache` | 5.1G | no |
| `/tmp/jest_rt` | 2.0G | no |
| `~/.local/share/opencode` | 1.4G | no |
| `~/.claude/projects` | 0.85G | no |
| `~/.npm/_cacache` | 0.65G | no |
| `~/.cache/ms-playwright` | 0.63G | no |
| `/tmp/node-compile-cache` | 0.35G | no |

### Why `treehouse prune` reclaimed none of the 32.4G

All 16 worktrees in the `optiroq-dev` pool were finished work.
Every one was skipped, on two independent counts.

```
$ treehouse status
1     leased       ~/.treehouse/optiroq-dev-9ae0cf/1/optiroq-dev
...
16    leased       ~/.treehouse/optiroq-dev-9ae0cf/16/optiroq-dev  (held by wt3)
```

First: every slot was still `leased`.
Crews had died or been killed without a clean teardown, so no lease was ever returned, and `treehouse prune` never takes a leased worktree.
That is correct behavior - a wedged crew and a dead crew look identical from outside, and prune cannot tell which one it would be destroying work for.

Second, and less obvious: every branch also read as *unmerged*.

```
$ git -C .../1/optiroq-dev merge-base --is-ancestor HEAD origin/master; echo $?
1
```

but

```
$ gh pr list --head docs/testing-coverage-implementation-plan --state all --json number,state
528 MERGED
```

All 15 named branches had a MERGED PR (#499, #500, #528, #571, #573, #574, #576, #577, #602, #604, #615, #619, #723, #727, #765); the sixteenth was a detached HEAD already an ancestor of master.
GitHub's "Squash and merge" replays a branch as one new commit on the base, so the branch's own commits never enter master's history and `merge-base --is-ancestor` answers "not merged" forever, however long ago the work shipped.
On a squash-merge repo this is the normal state of every landed branch, not an edge case.

Zero of the 16 had unpushed commits:

```
$ for i in $(seq 1 16); do git -C .../$i/optiroq-dev log --oneline @{u}..HEAD; done
(no output)
```

One (`wt-3`) was dirty, and only in lockfiles:

```
 M src/admin-app/package-lock.json
 M src/portal-ui/package-lock.json
```

### Why the scratch reaper had not run

`bin/fm-scratch-reap.sh` is invoked from exactly one place, `bin/fm-bootstrap.sh`, which runs at session start.
The primary session had been up for days, so the reaper had not run in days, while `/tmp/claude-1001/` grew to 22.6G across 74 session directories.
Several of those directories held full git clones and worktrees created by crews:

```
/tmp/claude-1001/-home-webjema-projects-optiroq-dev/b74b926b-.../scratchpad/ci-fix/.git
/tmp/claude-1001/-home-webjema--treehouse-optiroq-80b6c6-3-optiroq/ad1a46c5-.../scratchpad/clean1/.git
/tmp/claude-1001/-home-webjema--treehouse-optiroq-80b6c6-3-optiroq/ad1a46c5-.../scratchpad/clean2/.git
/tmp/claude-1001/-home-webjema--treehouse-optiroq-80b6c6-3-optiroq/ad1a46c5-.../scratchpad/clean3/.git
```

The two largest single trees were `-home-webjema-tools-firstmate/` at 8.5G and `-home-webjema--treehouse-optiroq-80b6c6-3-optiroq/` at 7.9G.

## Recovered

63G, by hand, in this order.
Nothing was lost: every destroyed worktree had a merged PR, no unpushed commits, and no dirty file other than lockfile churn.

| Action | Reclaimed |
| --- | --- |
| `treehouse destroy <path> --yes --include-leased --include-unlanded`, 16 times | 32.4G |
| 68 dead session scratch dirs under `/tmp/claude-1001/` | ~21G |
| `~/.npm-cache-shared/_cacache` | 5.1G |
| `/tmp/jest_rt`, `/tmp/node-compile-cache`, `/tmp/v8-compile-cache-*`, `/tmp/fm-*` test temps | 2.6G |
| `npm cache clean --force` | 0.3G |

```
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/root       154G   82G   73G  54% /
```

Two things had to be got right by hand and are the reason the fix is not "wipe `/tmp`".

**Live sessions do not announce themselves by mtime.**
Seven session scratch directories were still in use, and were identified by asking the OS, not the filesystem:

```
$ ls -l /proc/*/cwd | grep -o 'claude-1001/[^ ]*'
$ for p in /proc/[0-9]*; do tr '\0' ' ' < $p/cmdline; echo; done | grep -o '/tmp/claude-1001/[^ ]*'
```

One of them held a running Postgres, started the previous day, serving out of its scratchpad:

```
1727225 Thu Jul 30 18:27:44 2026 .../scratchpad/pgdist/root/usr/lib/postgresql/16/bin/postgres
  -D .../scratchpad/pgdata -p 55432
```

Its newest file mtime was over 6 hours old, so any age-based sweep tighter than that would have deleted a live database.

**Paths beginning with `-` are read as flags.**
The first deletion pass silently removed only 8 of 68 directories, because entries such as `-home-webjema-tools-firstmate/<uuid>/` were passed to `find` as relative paths and parsed as options.
Absolute paths fixed it.

## Fixed by

`bin/fm-disk-guard.sh`, added in the same change as this document, plus its two call sites.

The root cause is not a missing janitor.
It is that every janitor firstmate had was wired to a lifecycle event - bootstrap, teardown - and none was wired to the condition that actually matters, which is the disk being nearly full.
So the guard is a *trigger* first: it measures free space and escalates through tiers, and it runs from `bin/fm-watch.sh` on a flat 15-minute cadence as well as from `bin/fm-bootstrap.sh`, because the watcher is the only thing in firstmate that ticks on wall-clock time regardless of what the fleet is doing.

Three findings from this incident are encoded as hard rails, each with a test:

- The lease is never overridden, at any occupancy.
  Leased-and-landed worktrees are measured and reported with the exact release command, and left alone.
  On this box that was the entire 32.4G, so the report is the deliverable, not a fallback.
- The scratch window is only tightened below the reaper's 48h default when live sessions could be enumerated from the process table.
  If that probe fails, the window stays at 48h.
  This is the Postgres case above.
- Every unanswerable signal - `df` unparseable, `jq` absent, lease state unreadable, `gh` unauthenticated - spares the target.

The squash-merge finding is why the guard asks `gh` for a merged PR rather than trusting `merge-base --is-ancestor`: on this repo the ancestry check is wrong for every landed branch.
