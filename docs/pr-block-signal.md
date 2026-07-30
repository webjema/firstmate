# Blocking a merge from the PR itself

`AGENTS.md` section 6, step 3 owns the rule: when firstmate's review of an already-open PR finds a merge-stopping defect, the verdict goes on the PR, not only into the chat.
This doc owns the mechanics, the per-repo setup, and the verification record behind them.

## The incident this exists for

On 2026-07-30, PR #44 in this repo (`webjema/firstmate`) merged carrying seven confirmed defects while its crew was still fixing them.
An independent review had found all seven and firstmate had told the user not to merge.
The verdict existed only in that firstmate session's chat, so the person clicking merge acted without it.
One of the seven bricks a worktree pool slot on every warm, on Linux as well as macOS.

The generalizable failure is not "the review was late" - the review was on time and correct.
It is that a review verdict living only in chat does not reach the person who merges, including a collaborator who never sees that session at all.
Firstmate's normal review sits before the PR exists, which keeps this rare, but once a PR is open the chat is no longer where the merge decision happens.

An advisory mark - a title prefix, or a comment on its own - is what already failed: it informs a reader who looks, and the merge button stays live for one who does not.
Prefer the mechanism that blocks.

## firstmate-authored PRs

Convert the PR to draft, which disables GitHub's merge button outright, and comment the verdict so the reason travels with the PR:

```sh
gh pr ready --undo <pr-url>                    # blocks the merge button
gh pr comment <pr-url> --body-file verdict.md  # carries the reason
```

Restore it with `gh pr ready <pr-url>` once the fix lands and the re-review is clean.

`--undo` is plan-gated (`gh pr ready --help`: "If supported by your plan").
It fails loudly - a GitHub API error and a non-zero exit - never silently, so treat a non-zero exit as the signal to fall back to the bot-authored path below on the same PR.

Two things hold while a PR sits drafted:

- PR CI keeps running on every push, so the fix loop keeps its gate (see the verification record).
- `bin/fm-pr-merge.sh` fails closed, because GitHub refuses to merge a draft PR at the API. That is defense in depth, not a bug to route around: mark the PR ready first, then merge on the user's word.

## Bot-authored PRs

Never draft a bot's PR - Dependabot and similar bots act on their own PR's state, and drafting can interfere with that handling.
Use a comment plus a blocking label:

```sh
gh pr comment <pr-url> --body-file verdict.md
gh pr edit <pr-url> --add-label do-not-merge
```

The label is advisory by itself; make it bite by requiring its absence in the repo's branch protection or merge-queue rules where that is configured.
Remove it with `gh pr edit <pr-url> --remove-label do-not-merge`.

`do-not-merge` is not a stock GitHub label and does not exist in most repos.
Create it once per repo, on first use:

```sh
gh label create do-not-merge --color B60205 --description "Blocking review defect - do not merge" --force
```

`--force` updates an existing label instead of failing, so the command is safe to re-run.

Authorship and current draft state both come out of the `gh-axi pr view <pr>` firstmate already reads (`author:` and `draft:` lines); `gh pr view <pr-url> --json author --jq .author.is_bot` is the exact read when the distinction is not obvious from the login.
Every mark above is a mutation, so it runs on plain `gh`, per section 6's read/mutate split.

## Verification record

Run 2026-07-30 in `webjema/firstmate`, `gh version 2.96.0 (2026-07-02)`, authenticated as `ignovak` with `push` on the repo.

**1. Is `gh pr ready --undo` supported here, and how does it fail when it is not?**

```console
$ gh repo view webjema/firstmate --json visibility,isPrivate
{"isPrivate":false,"visibility":"PUBLIC"}
```

GitHub offers draft pull requests on every plan for public repositories; the plan gate bites on private repositories on Free.
This repo is public, and the underlying mutation is present in the API:

```console
$ gh api graphql -f query='{ __type(name:"Mutation"){ fields{ name } } }' --jq '.data.__type.fields[].name' | grep -i draft
convertPullRequestToDraft
...
```

The failure mode is loud, not silent:

```console
$ gh pr ready --undo 99999 --repo webjema/firstmate
GraphQL: Could not resolve to a PullRequest with the number of 99999. (repository.pullRequest)
$ echo $?
1
```

Not proven directly: a live draft conversion on this repo.
Doing that needs an open PR, and a crewmate may not open one before firstmate approves its branch.
The instruction is therefore written to key its fallback on the non-zero exit rather than on an assumption that the plan allows drafts, which makes it correct on either kind of plan.

**2. Does drafting suppress this repo's PR CI?**

No - which is what makes the draft path usable, and this was the check with the power to kill it.

```console
$ grep -n -A 5 "^on:" .github/workflows/ci.yml
9:on:
10-  push:
11-    branches: [main]
12-  pull_request:
13-    branches: [main]
$ grep -n "draft\|if:" .github/workflows/ci.yml
$ echo $?
1
```

The `pull_request` trigger carries no `types:` filter, so it uses the default activity types `opened`, `synchronize`, and `reopened`, all of which fire for draft PRs.
The workflow has no draft guard at all - the `if: github.event.pull_request.draft == false` idiom that repos use to opt out of draft CI is absent, and it exists precisely because draft PRs run workflows by default.
So Lint shell scripts, Behavior tests, and Repo invariants all keep running on every fix push while the PR is drafted.

One nuance worth knowing: `converted_to_draft` and `ready_for_review` are not default activity types, so neither drafting the PR nor marking it ready spawns a run by itself.
CI runs on the fix push, which is exactly when the gate matters.

**3. Does a `do-not-merge` label exist?**

No.

```console
$ gh label list --repo webjema/firstmate
bug, documentation, duplicate, enhancement, good first issue, help wanted, invalid, question, wontfix
```

Only the nine stock labels.
The label must be created per repo on first use, with the `gh label create ... --force` command above.
