# cloud-workstation

Host tooling for the cloud dev box this firstmate runs on.
It is deliberately not wired into `bin/` or any firstmate runtime path: these scripts shape the box's own terminal environment, not the fleet.

## start-hybrid.sh

Builds (or re-attaches to) the persistent `work` tmux session: the coordinator tab, the `wt1`/`wt2`/`wt3` worktree tabs, and the supporting tabs.
The script's own header owns the full layout, the worktree sync contract, and the `WORK_SESSION` test override.

**This repo copy is the source of truth.**
The deployed copy lives at `~/cloud-workstation/start-hybrid.sh` on the box and is updated by hand after a change merges.
Deploy step, verbatim:

```sh
cp ~/tools/firstmate/cloud-workstation/start-hybrid.sh ~/cloud-workstation/start-hybrid.sh
```

The smoke test is `tests/start-hybrid.test.sh`; it runs against a scratch tmux server on a private socket with stubbed `treehouse`/`claude`, so it never touches the live `work` session or the real treehouse pool.
