# Contributing

Thanks for wanting to contribute.

This fork ships changes through an ordinary pull request, gated by CI and by review.
There is no separate validation pipeline to install: the quality gate is Claude Code hooks, the built-in `/code-review` skill, and the CI workflow in `.github/workflows/ci.yml`.

## Workflow

1. Fork the repo and clone your fork.
2. Create a branch and make your changes.
3. Run the checks below locally.
4. Commit, push your branch, and open a PR against `main`.

CI runs `bin/fm-lint.sh` and the full bash behavior suite on every PR.
Branch protection requires those jobs to pass; a red PR is never merged.

## Repo conventions

- This repo is a template for running a firstmate orchestrator agent.
  `AGENTS.md` is the agent's main job description and names when to load bundled firstmate skills; `CLAUDE.md` is a symlink to it, and `.claude/skills` is a symlink to `.agents/skills`.
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/`.
  `.agents/skills/` holds agent-loaded skills that assume a live firstmate home and carry `metadata.internal: true` so installers such as [skills.sh](https://skills.sh) hide them from discovery; `skills/` holds standalone, installer-facing public skills with no firstmate dependency (see the README's "Two-tier skill layout").
  Everything personal to one user's fleet (`data/`, `state/`, `config/`, `projects/`) is gitignored; never commit it.
  In particular `data/directions/` holds each project's business vision and architecture posture: it is the user's, and it never leaves the fleet.
  The root `.tasks.toml` is tracked `tasks-axi` config for `data/backlog.md`.
  It does not make `data/` tracked.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; the header owns that script's contract, and `AGENTS.md` deliberately does not restate it.
  Keep the header accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `bin/fm-lint.sh` must pass: it is the single owner of the lint definition (the shellcheck file set, config, and pinned shellcheck version), and CI runs it, so local and CI can never diverge.
  It pins one exact shellcheck version and refuses to run under any other; print it with `bin/fm-lint.sh --required-version` and install that build locally.
- Changes to harness adapters (detection in `bin/fm-harness.sh`, launch and hook mechanics in `bin/fm-spawn.sh`, busy signatures in `bin/fm-watch.sh` and `bin/fm-tmux-lib.sh`, cleanup in `bin/fm-teardown.sh`, and facts in `.agents/skills/harness-adapters/SKILL.md`) must be verified empirically against the real harness, never written from documentation alone.
- In Markdown, put each full sentence on its own line.
- `README.md` stays a concise overview plus pointers: it never carries a wall of inline detail.
  Route detail to the most specific `docs/` file and link to it instead.

## Development

Tracked changes to firstmate itself ship on a feature branch through a PR and require an explicit merge approval.
Before making any such change, load the agent-only `firstmate-coding-guidelines` skill (`.agents/skills/firstmate-coding-guidelines/SKILL.md`).
It has the knowledge-placement rules that keep `AGENTS.md` from regrowing after each diet pass.

`AGENTS.md` is loaded into every session, so every word in it is paid for on every turn.
Treat its size as a budget, not a preference.
Knowledge that belongs to one lifecycle event goes in the skill that fires on that event; a contract that belongs to a script goes in that script's header; a file manifest goes in `docs/configuration.md`.
If you find yourself restating something a script header already owns, delete it instead.

When supervising live crewmates, keep firstmate's own long validation or build commands in the background so watcher wakes can still be handled.

Check and test the toolbelt before pushing:

```sh
for script in bin/*.sh; do bash -n "$script"; done   # syntax-check the toolbelt
bin/fm-lint.sh   # lint the toolbelt and behavior tests; the single owner CI runs
bin/fm-test.sh   # behavior tests, parallel; the single owner CI runs (bin/fm-test.sh --help)
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && FM_STATE_OVERRIDE="$tmp" FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh  # watcher re-arm smoke test
```

Discover tests with `bin/fm-test.sh --list`: each is a self-contained bash script named `<subject>.test.sh`, and its header comment describes what it covers, so run one directly (`bin/fm-test.sh tests/<subject>.test.sh`) to focus on a subject.
Tests that need an explicit opt-in skip themselves and print the gate needed to enable them, so the full run above is always safe.
Run the affected tests as you work and the full `bin/fm-test.sh` once at the end - it is parallel, so the whole suite costs about as long as its slowest single test.

## Questions

Open an issue.
