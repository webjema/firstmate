# codebase-memory CLI backend

The codebase-memory knowledge graph is firstmate's only optional backend: a cache that makes a crewmate's first look at a repo a query instead of a file-by-file crawl.
`bin/fm-graph-lib.sh` is the single owner of how firstmate talks to it.
This file is the verification record behind that header - the empirical evidence for what the binary actually accepts, and the incident that proves why the evidence has to be written down.

## What it is

`codebase-memory-mcp` is a single static binary that serves the graph over MCP and, with `cli`, runs one tool per invocation from a shell.
Firstmate uses only the shell form, and only two tools: `list_projects` to find out whether a clone is in the graph at all, and `index_repository` to refresh one that is.
It is optional throughout: [`docs/configuration.md`](configuration.md) owns the `graph-reindex-mode` knob, whose `off` value is the feature's complete kill switch.

## Verified surface

Verified 2026-08-15 against **codebase-memory-mcp 0.9.0** at `~/.local/bin/codebase-memory-mcp`, on Linux 6.17.0-1019-aws (x86_64).
Every block in this section was produced by 0.9.0.
Where 0.8.1 answered differently, its answer is kept alongside and labelled, because the argument surface and the error shape have each moved between the two, and a record that dropped the earlier one would make the next move look like it had always been that way.

A tool's arguments can be one positional JSON object, which is the form every version has accepted and the only form firstmate builds.
0.9.0 also takes flags, `--args-file`, and piped stdin, and deprecates the positional JSON; both sections below cover that.

```
$ codebase-memory-mcp --version
codebase-memory-mcp 0.9.0

$ codebase-memory-mcp cli
level=info msg=mem.init budget_mb=3904 total_ram_mb=15617
Usage: codebase-memory-mcp cli [--progress] [--json] <tool_name> [json_args]
```

`index_repository` takes `repo_path` (required), `name`, `mode`, `persistence`, and `target_projects`.

**`name` is what addresses an entry**, and 0.9.0 accepts it where 0.8.1 had no such argument at all.
Given a name, the binary writes that entry; given none, it derives one by slugging the resolved `repo_path`.
`project`, `project_name` and `target_projects` are *not* substitutes - each is accepted and silently ignored for this purpose, and the call lands on the slug:

```
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli index_repository '{"repo_path":"'"$P"'/repo","mode":"fast","persistence":false,"name":"shortname"}' 2>/dev/null | jq -c '{project,status,nodes}'
{"project":"shortname","status":"indexed","nodes":17}

$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli index_repository '{"repo_path":"'"$P"'/repo","mode":"fast","persistence":false,"project":"shortname2"}' 2>/dev/null | jq -c '{project,status,nodes}'
{"project":"tmp-...-probe-repo","status":"indexed","nodes":17}
```

Re-indexing under a name that already exists updates that entry in place rather than adding a second one.
The probe below is the fleet's own defect in miniature: one repo carrying both a short-named entry and a slug entry, grown by two functions, then refreshed by name.

```
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli index_repository '{"repo_path":"'"$P"'/repo","mode":"fast","persistence":false,"name":"shortproj"}' 2>/dev/null | jq -c '{project,nodes}'
{"project":"shortproj","nodes":17}
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli index_repository '{"repo_path":"'"$P"'/repo","mode":"fast","persistence":false}' 2>/dev/null | jq -c '{project,nodes}'
{"project":"tmp-...-probe2-repo","nodes":17}
                                       # two entries, one root_path
$ # ... add b.py with three functions, commit, then refresh BY NAME:
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli index_repository '{"repo_path":"'"$P"'/repo","mode":"fast","persistence":false,"name":"shortproj"}' 2>/dev/null | jq -c '{project,nodes}'
{"project":"shortproj","nodes":22}
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli list_projects 2>/dev/null | jq -c '[.projects[]|{name,nodes}]'
[{"name":"tmp-...-probe2-repo","nodes":17},{"name":"shortproj","nodes":22}]
```

Passing a name equal to the slug is the ordinary case and behaves identically, so `fm_graph_reindex` passes the recorded name unconditionally rather than only when it differs.

`name` can also **create** an entry that does not exist, which is why `bin/fm-graph-lib.sh` only ever passes one `fm_graph_project_for_path` just read back out of `list_projects`; that file's header owns the rule and `tests/fm-graph.test.sh`'s `test_unindexed_project_is_skipped_not_indexed` pins it.

The slug derivation, for a call given no name, is unchanged from 0.8.1: every character outside `[A-Za-z0-9._]` becomes a dash, runs of dashes collapse to one, and the ends are trimmed - so underscores, dots and case survive while a space, a quote, a plus or a tilde do not.

```
$ CBM_CACHE_DIR=/tmp/fm-slug-probe/cache codebase-memory-mcp cli index_repository '{"repo_path":"/tmp/fm-slug-probe/A_b+C d/e~f","mode":"fast","persistence":false}' 2>/dev/null | jq -r .project
tmp-fm-slug-probe-A_b-C-d-e-f
```

`tests/graph-helpers.sh`'s stub derives its answer by that same rule when handed no name, and honours the name when handed one.
A stub that always looked the path up in its own fixture would answer with the recorded name even for an unnamed call the binary would slug differently, and so would report a landing the binary never performs.

`list_projects` takes no arguments (`{}` and no argument behave identically) and in 0.9.0 reports `name`, `root_path`, `nodes`, `edges`, `size_bytes` **and a `git` block** per project, where 0.8.1 carried no `git` block at all.

```
$ codebase-memory-mcp cli list_projects 2>/dev/null | jq -c '.projects[0]|keys'
["edges","git","name","nodes","root_path","size_bytes"]
```

So `fm_graph_project_for_path`'s match on `git.canonical_root` is live on 0.9.0 rather than the latent allowance it was on 0.8.1.

A refresh reached that way updates the entry in place and **rewrites its `root_path`** to the path it was handed, which is a write the fleet did not previously make:

```
$ # entry seeded on a worktree, then refreshed at the clone the lookup matched by canonical_root:
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli list_projects 2>/dev/null | jq -c '.projects[]|{name,root_path,canonical_root:.git.canonical_root,nodes}'
{"name":"wt-proj","root_path":"$P/wt/tree","canonical_root":"$P/wt/clone","nodes":18}
$ CBM_CACHE_DIR=$P/cache FM_PROJECTS_OVERRIDE=$P/wt bin/fm-graph-reindex.sh clone
clone: graph refreshed (project=wt-proj, mode=full, nodes=22)
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli list_projects 2>/dev/null | jq -c '.projects[]|{name,root_path,canonical_root:.git.canonical_root,nodes}'
{"name":"wt-proj","root_path":"$P/wt/clone","canonical_root":"$P/wt/clone","nodes":22}
```

One entry throughout, no duplicate, and the repoint is toward the canonical root rather than away from it.
It is recorded because it is a side effect the caller does not ask for, not because it is a problem.

`list_projects` can hold **several entries with the same `root_path`**, and does on this fleet - one named by hand and one slugged by an unnamed refresh.
`fm_graph_project_for_path` returns the first match; the order was stable across repeated calls when probed.

```
$ codebase-memory-mcp cli list_projects 2>/dev/null | jq -r '[.projects[]|select(.root_path=="/home/webjema/tools/firstmate/projects/optiroq")|.name]|"matches: \(.)", "first: \(first)"'
matches: ["optiroq","home-webjema-tools-firstmate-projects-optiroq"]
first: optiroq
```

`index_status` reports node and edge counts, `status: ready`, and in 0.9.0 a `git` block carrying `head_sha` where 0.8.1 carried no SHA at all.
**That SHA is the checkout's live HEAD, not the commit the graph was built at**, so it cannot be compared against anything to detect staleness:

```
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli index_status '{"project":"shaproj"}' 2>/dev/null | jq -c '{nodes,status,head:.git.head_sha,base:.git.base_sha}'
{"nodes":18,"status":"ready","head":"44827152f3604ce6962027f8410ee8634bcc08bd","base":""}
$ git -C $P/repo rev-parse HEAD
44827152f3604ce6962027f8410ee8634bcc08bd
$ # one more commit, and NO reindex:
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli index_status '{"project":"shaproj"}' 2>/dev/null | jq -c '{nodes,status,head:.git.head_sha,base:.git.base_sha}'
{"nodes":18,"status":"ready","head":"56a6b98652a6ae7820748fff33e6aa3d00aca38c","base":""}
$ git -C $P/repo rev-parse HEAD
56a6b98652a6ae7820748fff33e6aa3d00aca38c
```

`nodes` stayed at 18 while `head_sha` moved on its own, and `base_sha` is empty on a fresh index.
So `ready` still means "a graph exists", never "a graph matching your checkout", which is precisely why a refresh that fails must say so loudly: nothing downstream can detect the staleness on its own.

## The flag form: rejected by 0.8.1, accepted again by 0.9.0

On 0.8.1 there was no flag form, and this is what the fleet's broken invocation ran into:

```
$ codebase-memory-mcp cli index_repository --repo_path /Users/inovak/dev/firstmate/projects/optiroq --mode full
level=info msg=mem.init budget_mb=24576 total_ram_mb=49152
repo_path is required
$ echo $?
1
```

`--repo-path` (hyphenated) failed identically.
The binary read the first argument after the tool as the JSON payload, could not parse `--repo_path` as one, and reported the required field as missing.

The JSON form succeeded, on the same box and the same repo:

```
$ codebase-memory-mcp cli index_repository '{"repo_path":"/Users/inovak/dev/firstmate/projects/optiroq","mode":"fast"}'
{"project":"Users-inovak-dev-firstmate-projects-optiroq","status":"indexed","nodes":33036,"edges":67045,...}
```

That incremental refresh took 1.3s, so the refresh itself was never the expensive part - only the invocation was wrong.

**0.9.0 accepts the flag form again**, `--name` included, and it is equivalent to the JSON form:

```
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli index_repository --repo_path $P/repo --name shortproj --mode fast 2>/dev/null | jq -c '{project,status}'
{"project":"shortproj","status":"indexed"}
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli index_repository '{"repo_path":"'"$P"'/repo","name":"shortproj","mode":"fast","persistence":false}' 2>/dev/null | jq -c '{project,status}'
{"project":"shortproj","status":"indexed"}
```

Firstmate keeps building the JSON form regardless, and `tests/graph-helpers.sh`'s stub keeps refusing flags, because the JSON object is the one shape that has worked across every surface this binary has had while the flag form has now flipped twice.
The suite no longer asserts that flags are rejected - that assertion was true of one version, not of the tool.
`test_real_cli_version_matches_the_verified_record` replaces it and pins the thing that actually generalizes: the installed version against the version this file records as verified.

## Diagnostics go to stderr

On failure the binary exits non-zero and writes both a plain reason and its JSON error payload to **stderr**, re-probed on 0.9.0:

```
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli index_repository '{"repo_path":"/no/such/dir","mode":"fast","persistence":false,"name":"nope"}' 2>&1 >/dev/null | grep -v level=info
warning: passing raw JSON to 'cli index_repository' is deprecated and will be removed in a future release; use flags (run 'cli index_repository --help'), --args-file <path>, or piped stdin.
level=warn msg=index.supervisor.worker_failed outcome=exit_nonzero exit_code=1 log=$P/cache/logs/.worker-1572193.log
level=warn msg=index.supervisor.worker_failed outcome=exit_nonzero exit_code=1 log=$P/cache/logs/.worker-1572193.log
{"status":"error","outcome":"exit_nonzero","hint":"Indexing worker crashed on a file. The crash was contained (the server survived). Re-run to retry; a future release isolates the culprit file.","repo_path":"/no/such/dir"}
$ echo $?
1
```

0.8.1 wrote a different shape here, `level=error msg=pipeline.err phase=discover rc=-1` plus a payload that carried a `project` key; 0.9.0's payload carries `repo_path` and no `project` at all.
Nothing downstream depended on either: `fm_graph_reindex` fails on `status != indexed` before it looks for a project, and stdout is empty on this path, so `fm_graph_call` fails first in any case.

Every call also logs several `level=info` progress lines to stderr whether or not it succeeds.
`fm_graph_distill` drops those and keeps the last two remaining lines, which is what lets a one-line warning carry the CLI's own words without carrying its chatter.
It filters `level=info` only, so the `level=warn` line above rides in as the plain reason alongside the payload, which is the useful half.

## The positional JSON form is deprecated in 0.9.0

Every call that passes raw JSON now warns on stderr, successes included:

```
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli list_projects '{}' 2>&1 >/dev/null | grep -i deprecat
warning: passing raw JSON to 'cli list_projects' is deprecated and will be removed in a future release; use flags (run 'cli list_projects --help'), --args-file <path>, or piped stdin.
$ CBM_CACHE_DIR=$P/cache codebase-memory-mcp cli list_projects 2>&1 >/dev/null | grep -i deprecat
$
```

Passing no argument at all raises no warning, which is why the fleet's `list_projects` calls are quiet and only `index_repository` is affected today.
`--help` names the four accepted forms and the flag spellings:

```
$ codebase-memory-mcp cli index_repository --help
Usage:
  codebase-memory-mcp cli index_repository --flag value [--flag2 value2 ...]
  codebase-memory-mcp cli index_repository --args-file <path-to-json>
  echo '<json>' | codebase-memory-mcp cli index_repository
  codebase-memory-mcp cli index_repository '<raw-json-args>'

Flags:
  --repo-path <string> [required]  Path to the repository
  --mode <string>  ...
  --target-projects <array>  ...
  --name <string>  Override the derived project name. Non-ASCII bytes are encoded and unsafe path characters are normalized.
  --persistence <boolean>  ...
```

So the one shape both recorded versions accept is also the shape on its way out.
Firstmate has not moved: raw JSON still works on 0.9.0, the warning is on stderr where nothing parses it, and `--args-file` and piped stdin both take the same jq-built object, so the migration is small and can be made deliberately when the fleet's owner chooses a floor version.
`test_real_cli_version_matches_the_verified_record` is what surfaces the next move, since a version bump reddens the suite until this record is re-derived.

## Isolating the graph in tests

`CBM_CACHE_DIR` relocates the graph database, and it isolates completely: with it set to an empty directory, `list_projects` reports only what was indexed under it.

```
$ CBM_CACHE_DIR=/tmp/probe-cache codebase-memory-mcp cli list_projects 2>/dev/null | jq -c '.projects|map(.name)'
[]
```

`tests/fm-graph.test.sh`'s real-CLI cases set it to a directory under the test's own temp root, so running the suite never adds, refreshes, or deletes an entry in the graph the user works from.
This is what makes it safe for the suite to drive the installed binary for real rather than only a stub.

The suite asserts that isolation rather than resting on this record of it.
`test_real_cli_refreshes_an_indexed_project` indexes its fixture under one throwaway cache and then reads a second, empty one, which must not see it.
If a later binary renamed or dropped the variable, both reads would hit the one graph the user actually works from - which would by then hold a throwaway fixture pointing at a directory the suite is about to delete - and without the assertion the run would stay green while littering it once per run.

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
- The suite asserted only the string firstmate builds, which stayed self-consistently green while it no longer matched anything real; `tests/fm-graph.test.sh` now drives the installed binary end to end, skipping cleanly where the binary is absent.

The general lesson, and the reason this file exists: a header comment claiming a verified external surface is a claim with an expiry date, and only a test that touches the real thing keeps it honest.

## Incident: the unreachable entry, 2026-07-29 to 2026-08-15

The same graph, the next layer down.
`fm_graph_reindex` sent only `repo_path`, so the binary slugged the path and wrote the slug entry - but `fm_graph_project_for_path` returns the graph's *recorded* name, and this fleet's graph held two entries on one `root_path`: `optiroq`, indexed by hand, and `home-webjema-tools-firstmate-projects-optiroq`, created by the first unnamed refresh.
`optiroq` is the name the lookup returns, so it is the name `bin/fm-brief.sh` hands to every crew - and no refresh ever reached it.
It sat at the commit it was first indexed at while crews queried it as current.

Until the 2026-08-09 fix above there was no evidence of this at all: the refresh printed a green `graph refreshed` line for the entry it had not written.
That fix added the response check, which turned the silence into a warning on every merge, but could not make the refresh land - it named a mismatch that nothing could resolve.
`tests/fm-graph.test.sh` had pinned the hole and said closing it was out of scope.

0.9.0's `name` argument closes it: the refresh is addressed by the name the lookup read out of the graph, and the response check stays as the proof it landed - and as the guard for any binary that ignores the argument.
The `optiroq` entry above is still the one to watch, because nothing in this fix removes the duplicate slug entry beside it; only the recorded name is refreshed, which is the entry anything downstream actually reads.

The lesson layered on the first: a verification that cannot pass is not a verification, it is a permanent alarm.
Making a failure loud is necessary and is not the same as making the success reachable, and the gap between the two is easy to mistake for done.

## Re-verifying after a binary update

Run `bin/fm-test.sh tests/fm-graph.test.sh`.
The `test_real_cli_*` cases drive the installed binary, so a surface change fails there rather than on the fleet.
`test_real_cli_version_matches_the_verified_record` fails on any version this file has not been re-verified against, which is deliberate: it is the expiry date above made mechanical.
It reads the version out of the `Verified <date> against **codebase-memory-mcp <version>**` line that opens "Verified surface", so that line's wording is load-bearing, and it also asserts that `bin/fm-graph-lib.sh`'s header names the same version - a header drifting from this record is how it came to assert a surface the binary did not have.
When one does fail, re-derive the surface with `codebase-memory-mcp --help` and `codebase-memory-mcp cli`, update `bin/fm-graph-lib.sh`'s CLI-SURFACE block with the new version and date, and update this file's evidence with the exact commands and output you ran.
