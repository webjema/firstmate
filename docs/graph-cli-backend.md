# codebase-memory CLI backend

The codebase-memory knowledge graph is firstmate's only optional backend: a cache that makes a crewmate's first look at a repo a query instead of a file-by-file crawl.
`bin/fm-graph-lib.sh` is the single owner of how firstmate talks to it.
This file is the verification record behind that header - the empirical evidence for what the binary actually accepts, and the incident that proves why the evidence has to be written down.

## What it is

`codebase-memory-mcp` is a single static binary that serves the graph over MCP and, with `cli`, runs one tool per invocation from a shell.
Firstmate uses only the shell form, and only two tools: `list_projects` to find out whether a clone is in the graph at all, and `index_repository` to refresh one that is.
It is optional throughout: [`docs/configuration.md`](configuration.md) owns the `graph-reindex-mode` knob, whose `off` value is the feature's complete kill switch.

## Verified surface

Verified 2026-08-10 against **codebase-memory-mcp 0.8.1** at `~/.local/bin/codebase-memory-mcp`, on macOS 25.5.0 (arm64).

A tool's arguments are one positional JSON object.
There is no flag form.

```
$ codebase-memory-mcp --version
codebase-memory-mcp 0.8.1

$ codebase-memory-mcp cli
level=info msg=mem.init budget_mb=24576 total_ram_mb=49152
Usage: codebase-memory-mcp cli [--progress] [--json] <tool_name> [json_args]
```

`index_repository` takes `repo_path` (required), `mode`, `persistence`, and `target_projects`.
It takes **no name**: 0.8.1 always derives the project name from the resolved repo path, so a refresh reaches the recorded entry only when that entry's name is the derived one.
This is why `fm_graph_reindex` passes the resolved path and then checks the `project` the response reports, instead of asserting the target with a flag that no longer exists.

`list_projects` takes no arguments (`{}` and no argument behave identically) and, in 0.8.1, reports `name`, `root_path`, `nodes`, `edges`, and `size_bytes` per project - with **no `git` block**.
`fm_graph_project_for_path` still accepts a match on `git.canonical_root` because an entry may carry one from another producer, but on 0.8.1 every match is on `root_path`.

`index_status` reports node and edge counts and `status: ready` with **no commit SHA**.
`ready` therefore means "a graph exists", never "a graph matching your checkout", which is precisely why a refresh that fails must say so loudly: nothing downstream can detect the staleness on its own.

## The flag form, and why it fails

```
$ codebase-memory-mcp cli index_repository --repo_path /Users/inovak/dev/firstmate/projects/optiroq --mode full
level=info msg=mem.init budget_mb=24576 total_ram_mb=49152
repo_path is required
$ echo $?
1
```

`--repo-path` (hyphenated) fails identically.
The binary reads the first argument after the tool as the JSON payload, cannot parse `--repo_path` as one, and reports the required field as missing.

The JSON form succeeds, on the same box and the same repo:

```
$ codebase-memory-mcp cli index_repository '{"repo_path":"/Users/inovak/dev/firstmate/projects/optiroq","mode":"fast"}'
{"project":"Users-inovak-dev-firstmate-projects-optiroq","status":"indexed","nodes":33036,"edges":67045,...}
```

That incremental refresh took 1.3s, so the refresh itself was never the expensive part - only the invocation was wrong.

## Diagnostics go to stderr

On failure the binary exits non-zero and writes both a plain reason and its JSON error payload to **stderr**:

```
$ codebase-memory-mcp cli index_repository '{"repo_path":"/no/such/dir","mode":"fast"}' 2>&1 >/dev/null | tail -2
level=error msg=pipeline.err phase=discover rc=-1
{"project":"no-such-dir","status":"error","hint":"Pipeline failed. Check repo_path exists and contains source files. ..."}
```

Every call also logs several `level=info` progress lines to stderr whether or not it succeeds.
`fm_graph_distill` drops those and keeps the last two remaining lines, which is what lets a one-line warning carry the CLI's own words without carrying its chatter.

## Isolating the graph in tests

`CBM_CACHE_DIR` relocates the graph database, and it isolates completely: with it set to an empty directory, `list_projects` reports only what was indexed under it.

```
$ CBM_CACHE_DIR=/tmp/probe-cache codebase-memory-mcp cli list_projects 2>/dev/null | jq -c '.projects|map(.name)'
[]
```

`tests/fm-graph.test.sh`'s real-CLI cases set it to a directory under the test's own temp root, so running the suite never adds, refreshes, or deletes an entry in the graph the user works from.
This is what makes it safe for the suite to drive the installed binary for real rather than only a stub.

## Incident: the silent refresh, 2026-07-29 to 2026-08-09

`bin/fm-graph-lib.sh` was written against a CLI that accepted flags, and its header recorded that surface as "verified 2026-07-29".
The binary later moved to 0.8.1's JSON-only surface.
From then on every automated refresh failed, and each merge-triggered teardown printed one line:

```
optiroq: graph refresh failed for project 'Users-inovak-dev-firstmate-projects-optiroq' (mode=full); graph may be stale
```

The refresh is best-effort by contract, so nothing went red and nothing stopped.
It was caught on 2026-08-09, after firing twice in one session, only because someone happened to read the teardown output.

Three things had to be true at once for a fortnight of failures to stay invisible, and the fix addresses all three.

- The invocation was wrong, so it is now built with `jq` against the verified JSON surface.
- The warning named no cause, so `"failed"` was indistinguishable from noise; every failure now quotes the CLI's own diagnostic.
- The suite asserted only the string firstmate builds, which stayed self-consistently green while it no longer matched anything real; `tests/fm-graph.test.sh` now drives the installed binary end to end and asserts that the old flag form is still rejected, skipping cleanly where the binary is absent.

The general lesson, and the reason this file exists: a header comment claiming a verified external surface is a claim with an expiry date, and only a test that touches the real thing keeps it honest.

## Re-verifying after a binary update

Run `bin/fm-test.sh tests/fm-graph.test.sh`.
The `test_real_cli_*` cases drive the installed binary, so a surface change fails there rather than on the fleet.
When one does fail, re-derive the surface with `codebase-memory-mcp --help` and `codebase-memory-mcp cli`, update `bin/fm-graph-lib.sh`'s CLI-SURFACE block with the new version and date, and update this file's evidence with the exact commands and output you ran.
