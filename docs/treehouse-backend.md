# treehouse worktree pool - verified behavior

[treehouse](https://github.com/kunchenguid/treehouse) maintains the pool of reusable git worktrees every crewmate works in.
This file records what was empirically verified about it, with the commands and output that verified it.
It is evidence, not design: `bin/fm-pool-warm.sh` owns the warm policy and `bin/fm-worktree-provision.sh` owns the provisioning contract.

## Hooks in a repo's own `treehouse.toml` are IGNORED

**Read this before proposing a `treehouse.toml` in a project clone to install dependencies.
It cannot work, and no amount of syntax fiddling will make it work.**

`post_create` and `pre_destroy` run only from the **user-level** config at `~/.config/treehouse/config.toml`.
A `[hooks]` block in the repo's own `treehouse.toml` is read and discarded.
This is deliberate on treehouse's part - a repo you clone should not be able to run commands on your machine the first time you get a worktree from it - so it is a designed boundary, not a bug to route around or a version to wait out.

Repo-level `treehouse.toml` is still honored for everything else, including `max_trees` and `root`.

### Evidence

Verified 2026-07-28 on macOS 25.5.0, treehouse v2.1.0 (`/Users/inovak/.local/bin/treehouse`, built 2026-07-20), against a throwaway git repo with one commit.
The two runs differ in exactly one thing: where the hook is written.

**Run 1 - the hook in the repo's own `treehouse.toml`, and no user-level config at all.**

```console
$ cat treehouse.toml
max_trees = 2

[hooks]
post_create = ["touch /tmp/scratch/REPO_LEVEL_HOOK_RAN"]

$ ls -l ~/.config/treehouse/config.toml
ls: /Users/inovak/.config/treehouse/config.toml: No such file or directory

$ treehouse get --lease --lease-holder hookprobe
🌳 Setting up worktree...
🌳 Leased worktree at ~/.treehouse/hookprobe-887fd6/1/hookprobe. ...
/Users/inovak/.treehouse/hookprobe-887fd6/1/hookprobe

$ ls -l /tmp/scratch/REPO_LEVEL_HOOK_RAN
ls: /tmp/scratch/REPO_LEVEL_HOOK_RAN: No such file or directory
```

The hook did not run.
treehouse reported no error and no warning - it simply ignored the block.

**Run 2 - the same repo, the same `treehouse.toml` left in place, the hook ALSO written to the user-level config.**

```console
$ cat ~/.config/treehouse/config.toml
[hooks]
post_create = ["touch /tmp/scratch/USER_LEVEL_HOOK_RAN"]

$ treehouse get --lease --lease-holder hookprobe2
🌳 Setting up worktree...
🌳 Leased worktree at ~/.treehouse/hookprobe-887fd6/1/hookprobe. ...

$ ls -l /tmp/scratch/USER_LEVEL_HOOK_RAN
-rw-r--r--  1 inovak  wheel  0 Jul 28 12:12 .../USER_LEVEL_HOOK_RAN

$ ls -l /tmp/scratch/REPO_LEVEL_HOOK_RAN
ls: /tmp/scratch/REPO_LEVEL_HOOK_RAN: No such file or directory
```

The user-level hook ran; the repo-level one still did not.
An earlier pass on 2026-07-27 reached the same result across four slot creations and every syntax form the block accepts (inline array, multi-line array, `[hooks]` at top level and nested), so this is not a formatting mistake.

Both the user-level config and the probe pool were removed afterwards; firstmate does not write either.

### The hook contract, for the record

Verified in the same runs, in case a future design does use the user-level config:

- `post_create` and `pre_destroy` are **arrays of strings**, each run sequentially through `/bin/sh -c`.
- The working directory is the worktree.
- They run on **both** a fresh worktree creation and a slot reset - run 2 above fired on a reset of the slot run 1 had already created.
- A non-zero exit is logged and does **not** fail the `get`.
- The user-level config has **no per-repo sections**: a hook there runs for every repo on the box.

### What firstmate does instead

Nothing.
Firstmate installs no hook and writes no `treehouse.toml`, because the only working hook home is global to every repo on the user's machine.
`bin/fm-pool-warm.sh` provisions dependencies itself, inside the treehouse lease it already holds, by calling `bin/fm-worktree-provision.sh`.
That writes only inside the leased worktree and under `~/.treehouse/` itself - the dependency cache at `.fm-dep-cache/`, the cache lock under `.fm-warm-locks/`, and a transient clone probe - so it needs no exception to firstmate's read-only posture toward `projects/`.

Verified 2026-07-28 by audit rather than by reading the code: a marker file was stamped, a real provisioning run of `~/.treehouse/optiroq-84584f/1/optiroq` was performed (three roots, 53 s), and `find <firstmate-home>/projects -newer <marker>` and `find ~/.config -newer <marker>` were both **empty**.

The accepted cost: a `treehouse get` that finds no warm slot still hands over an empty worktree and the crew installs for itself.
That is exactly the behavior that predates the provisioning script, and the always-plus-one warm invariant closes it in steady state.

## `treehouse get` hands over an EMPTY worktree

A corollary of the above, and worth stating plainly because a header in this repo once claimed otherwise: treehouse installs nothing.
It creates or resets a worktree and hands it over.
Everything in `node_modules` is put there by firstmate's warm path or by the crew itself.

## A returned slot keeps its dependencies

treehouse's reset is `git clean -fd` with **no** `-x`, so gitignored trees survive a `treehouse return`.
That is the whole reason a warmed slot stays warm.

Verified 2026-07-14 (treehouse v2.0.0, optiroq): after the return, `node_modules/`, `src/portal-ui/node_modules/` and `src/admin-app/node_modules/` were all still present - 2.7 GB intact.

## APFS clone savings are invisible to `du`

`cp -c` on APFS makes a copy-on-write clone: the copy shares its blocks with the source until one of them is written.
`du` counts every block a file references, whether or not it is shared, so a cloned tree looks full-size to `du` and to anything built on it.
Only free-space accounting shows the truth.
Measure with `df` before and after, never `du`.

Measured 2026-07-27 on optiroq (three install roots, warm shared npm cache, all slots idle):

| | wall time | real disk (`df` delta) |
| --- | --- | --- |
| cold install from scratch | 56 s | 2,832,680 KB = 2.70 GB |
| clone from cache + reconcile | 53 s | 98,660 KB = 96 MB |

96.5% less real disk per additional slot.
Time is essentially unchanged: `npm install` dominates and the npm cache is already shared, so this buys disk, not speed.
The provisioned slot was proven correct by building in it - `npm run build` at the repo root and in `src/portal-ui`, both exit 0 - not by listing directories, which a cloned tree would pass trivially.
