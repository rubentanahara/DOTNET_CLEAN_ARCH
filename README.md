# How to use the agent harness

DOTNET_CLEAN_ARCH: from a GitHub issue to a merged story.

## Contents

1. [What it is](#1-what-it-is)
2. [One-time setup](#2-one-time-setup)
   - [Make targets](#21-make-targets)
3. [The daily flow](#3-the-daily-flow)
   - [Write a story](#31-write-a-story)
   - [Run the runner](#32-run-the-runner)
   - [Which story runs first](#33-which-story-runs-first)
4. [Runner options](#4-runner-options)
5. [Test-first is enforced](#5-test-first-is-enforced)
6. [Working by hand, in one session](#6-working-by-hand-in-one-session)
   - [Start over with an empty backlog](#61-start-over-with-an-empty-backlog)
7. [GitHub stays in sync](#7-github-stays-in-sync)
8. [Rules the harness enforces](#8-rules-the-harness-enforces)
9. [When something goes wrong](#9-when-something-goes-wrong)
10. [Limits to know about](#10-limits-to-know-about)
11. [Where to read more](#11-where-to-read-more)

## 1. What it is

The harness turns a story written on GitHub into reviewed, tested code on `main` with almost no manual steps. The repository is a .NET 10 Clean Architecture API template. `feature_list.json` is the backlog, and it is the single source of truth. GitHub issues and the project board are a live view of it.

The flow, end to end:

1. You open a Story issue on GitHub.
2. A GitHub Action adds the story to `feature_list.json` through a pull request that merges itself (about 3 minutes).
3. You run `scripts/agent/run.sh`. An agent builds the story test-first, a second fresh session reviews it, and the runner opens a pull request.
4. CI runs `make check`. The runner merges the pull request, and the board card moves to Done.

Everything is checked by `make check`. It is the only definition of green.

## 2. One-time setup

| Step | Command or action |
| --- | --- |
| Install tools and git hooks | `make setup` |
| Confirm the repo is green | `make check`. It prints `OK <step>` for each step that passes, then `CHECK PASSED: ...` |
| Install the CLIs you want to use | GitHub Copilot CLI (default), Claude Code, Codex |
| Log in to gh | `gh auth login` |
| Repository secret | `BACKLOG_SYNC_TOKEN`: a classic token with `repo`, `workflow`, `project`, `read:org` and `read:discussion` |
| Repository setting | Allow auto-merge: `gh repo edit --enable-auto-merge` |
| Branch protection on `main` | Require a pull request and the `check` job |

### 2.1 Make targets

Every target says how it ended.

| Command | Does | Output |
| --- | --- | --- |
| `make setup` | Restores tools and packages, installs git hooks | `OK setup` |
| `make check` | Runs every check: hooks, skills, agents, harness, packages, build, format, tests, smoke | `OK <step>` per step, then `CHECK PASSED`, or `CHECK FAILED at <step>` with the failing lines and the fix |
| `make format` | Fixes formatting and line endings | `OK format` |
| `make run` | Starts the API on `http://localhost:5001` (Swagger at `/swagger`, health at `/health`) | runs until stopped |
| `make clean` | Removes build artifacts and logs | `OK clean` |
| `make rename NAME=<Name>` | Renames the template to `<Name>` and replaces the git history with a fresh `git init` | `OK rename ...` or `RENAME FAILED` with the reason |

For a new project, run `make rename NAME=Acme.Billing` once, on a clean tree with everything committed and pushed. It refuses to run otherwise, and it throws away the old git history.

Each step writes its full output to `.agent/` (`build.log`, `lint.log`, `test.log`, `smoke.log`, `harness.log`).

The token and auto-merge are needed only for the GitHub-to-repo sync. The runner itself works without them if you run it with `--no-merge` and merge by hand.

## 3. The daily flow

### 3.1 Write a story

Open a new issue and choose the Story form. Fill in:

- **Epic**: the id of an existing epic, for example `EPIC-OPERATIONS`.
- **Name** and **Story**: "As a …, I want … so that …".
- **Acceptance criteria**: one Given, When, Then per line.
- **Test filter**: a `dotnet test` filter, for example `FullyQualifiedName~VersionEndpointTests`.
- **Depends on**: story ids, one per line.
- **Owns**: the repo paths the story may change, one per line. End a directory with `/`.
- **Priority**, **Estimate**, **Area**.

Within about three minutes a pull request named `chore: sync backlog from GitHub` merges itself. The issue is renamed `F<nn> · <name>` and a card appears on the board. If the backlog refuses the story, the issue gets a `rejected` label and a comment that says why. Fix the issue, then remove the label to try again.

For a larger feature, use the `prd` skill to write a requirements document and the `backlog` skill to cut it into stories.

### 3.2 Run the runner

Start from a clean `main` checkout. The runner branches from it and its pull requests target it.

```sh
scripts/agent/run.sh --dry-run   # show the plan, start nothing
scripts/agent/run.sh             # run the first wave of ready stories
```

For each story the runner:

1. Creates a worktree in `.worktrees/<id>` and runs `feature.sh start`.
2. Starts the implementer, a headless session named `<id> · <name>`.
3. Runs the gate: `make check`, the scope check, a `PROGRESS.md` mention, the TDD commit-order check, and the story's tests.
4. Starts a fresh, read-only reviewer session that runs the `verify` skill.
5. Runs `feature.sh done`, then commits, pushes, and opens a pull request that says `Closes #<issue>`.
6. Waits for CI, then squash-merges, pulls `main`, and syncs the board. It then looks for the next wave.

Each node gets three attempts. After the third failure the story is blocked, with the last finding as the reason.

### 3.3 Which story runs first

`feature.sh waves` decides. Only stories that are `not_started` or `active` and in a numbered sprint count. A story waits until everything in its `depends_on` is passing. A story in an earlier sprint runs before a later one. Stories that own the same path run in different waves, and a story with no `owns` runs alone. The runner takes only the first wave. Use `--story <id>` to force one story.

## 4. Runner options

| Option | Meaning | Default |
| --- | --- | --- |
| `--cli` | CLI that implements: `claude`, `codex` or `copilot` | `copilot` |
| `--checker` | CLI that reviews | same as `--cli` |
| `--model` | Model of the implementer | `claude-sonnet-5.5` (Copilot) |
| `--checker-model` | Model of the reviewer | `claude-opus-5.5` (Copilot) |
| `--parallel N` | Run N stories of a wave at once, one tmux pane each | `1` |
| `--no-merge` | Stop at open pull requests instead of merging | merge is on |
| `--story <id>` | Run only this story | the whole first wave |
| `--dry-run` | Print the plan only | off |

Model ids differ per CLI. Copilot spells them with a dot (`claude-sonnet-5.5`), Claude Code with a dash (`claude-sonnet-5-5`). For Codex, list valid ids with `codex debug models`. Inside an interactive `copilot` session, `/model` shows the models your plan offers.

Examples:

```sh
# Copilot implements with Sonnet and reviews with Opus (the defaults)
scripts/agent/run.sh

# Copilot implements, Codex reviews (a second vendor checks the work)
scripts/agent/run.sh --cli copilot --checker codex

# Two independent stories at once, stopping at open pull requests
scripts/agent/run.sh --parallel 2 --no-merge
```

Reviewing with the same CLI that implemented is a weaker check than using a second CLI. Use `--checker` when the change matters.

## 5. Test-first is enforced

The implementer must make its first commit contain only files under `tests/`, named `test(<id>): ...`. The gate checks that commit out in a throwaway worktree and runs the story's test filter on it. The tests must fail. A compile error counts as a failure, and a filter that matches nothing is refused. The implementer then commits the code as `feat(<id>): ...`.

If the order is wrong, the gate sends the agent back with the exact fix: reset with `git reset --soft`, recommit the tests alone, then the code.

## 6. Working by hand, in one session

You can also work a story yourself in any supported CLI. Start the CLI in the repo. It reads `AGENTS.md`, a short router with the hard rules at the top and the Definition of Done at the bottom. A table in it says which file to read for which task.

The session-start hook injects the state: the `make check` result first, then the backlog, then `PROGRESS.md`. The text is cut to 9,000 characters, because Claude Code keeps at most 10,000 characters of a hook's output. The cut falls on `PROGRESS.md`, and a note says where the rest is.

| Skill | Use |
| --- | --- |
| `/prd` | Write requirements in `docs/prd/` |
| `/backlog` | Cut a PRD into stories with `feature.sh add` |
| `/feature` | Work one story |
| `/tdd` | Build it one acceptance criterion at a time, test first |
| `/verify` | Independent read-only review. Run it in a fresh session |
| `/ship` | Commit and open the pull request |
| `/grilling` | Stress-test a plan |
| `/handoff` | Summarize the session for the next one |

In Codex, call skills with `$<name>` instead of `/<name>`.

The `feature.sh` commands:

| Command | Does |
| --- | --- |
| `status` | Progress per sprint and every story not passing |
| `waves` | Open stories grouped into parallel waves |
| `show <id>` | One story with its epic and sprint |
| `start <id>` | Make a story active (one at a time) |
| `done <id>` | Mark it passing, only after `make check` and its own tests pass |
| `block <id> "<reason>"` | Park a story that something outside the repo stops |
| `unblock <id>` | Make a blocked story startable again |
| `scope <id>` | List changed files outside the story's `owns` |
| `add < fragment.json` | Add epics, stories and sprints |
| `reset` | Remove every sprint, epic and story. Keeps `project_title`, `priority_legend` and `shared`. Refuses while a story is active |

Never edit `feature_list.json` by hand. Use `feature.sh`.

### 6.1 Start over with an empty backlog

After `make rename`, the repo and the board are new, so only the file needs emptying. Run `scripts/agent/feature.sh reset`, then add your own stories with `feature.sh add`.

If the backlog is already on GitHub, the old issues must go too. The sync finds issues by the id in their title, so a new `F01` would take over the old `F01 · ...` issue.

1. On a branch, run `scripts/agent/feature.sh reset`.
2. Run `scripts/agent/github-sync.sh reset`. It lists what the sync owns: issues with its marker, issues labelled `story`, and the project.
3. Run `scripts/agent/github-sync.sh reset --yes` yourself in a terminal and type the repo name. It deletes those issues and the project for good. It refuses without a terminal, so an agent cannot run it.
4. Open the pull request. After the merge, the sync creates an empty project.

## 7. GitHub stays in sync

| You do this on GitHub | What happens |
| --- | --- |
| Open a Story issue | The story is added to the backlog by a sync pull request |
| Edit a story issue's text, criteria, tasks, depends on, owns, or its priority, estimate and area labels | A sync pull request writes it into `feature_list.json` |
| Rename an issue, or edit an epic's title or summary | The same sync applies it |
| Move a card to Blocked, or back to Todo | `feature.sh block` or `unblock` runs in the next sync |
| Move a card to Done by hand | The card is set back, with a comment. Only `feature.sh done` passes a story |
| Merge to `main` | The push job syncs issues and cards. Passing stories close their issues |

Syncs run on issue events and every 15 minutes. Only people with write access can change the backlog this way. The edit is validated first. An edit that is invalid or that breaks the dependency order is reported and left alone. If both sides changed the same field, it is a conflict and nothing is overwritten.

Do not run `scripts/agent/github-sync.sh push` from a feature branch. It would move passing cards back to In Review. Run it from `main`.

## 8. Rules the harness enforces

- Never edit or delete a test to make it pass. Fix the code.
- Never silence analyzers. No `#pragma warning disable`, no `NoWarn`.
- Add NuGet packages only through `Directory.Packages.props`, and ask first.
- Commit, push and open pull requests only on request. Conventional Commits only. Never push to `main`, never force-push.
- `.husky/pre-push` refuses every push to `main` and every push that drops commits already on the remote. Git runs it for all three CLIs and for people. It reads the refs git is about to push, so `HEAD:main`, `+main` and `git push -u origin main` are refused too.
- Deleting the backlog's GitHub issues needs a person at a terminal.
- A story changes only the files it owns. `feature.sh done` refuses anything else.
- A stop hook runs `make check` on uncommitted changes and sends the agent back if it fails.
- `PROGRESS.md` must say what changed, why, and what comes next.

## 9. When something goes wrong

| Symptom | Cause and fix |
| --- | --- |
| The runner says the working tree is not clean | Commit or stash. It needs a clean checkout of the default branch |
| The runner stops with "CI failed" | Read the pull request's check. A CI failure stops the run. Fix on the branch, then merge by hand |
| A story is blocked after three attempts | Read `.agent/runs/<id>/` for the logs and the last finding. Fix the cause, run `feature.sh unblock <id>`, run the runner again |
| The gate says "TDD rule" | The first commit mixed tests and code, or its tests passed. Follow the fix in the message |
| A story needs a file outside its `owns` | The agent blocks the story. Widen `owns` in a pull request, then unblock it |
| A sync pull request does not appear | Open the Actions tab and read the Backlog sync run |
| `unknown owner type` or missing scopes in Actions | `BACKLOG_SYNC_TOKEN` lacks a scope. Add `read:org` and `read:discussion` |
| A merge shows `BEHIND` | The runner updates the branch itself. If there are conflicts, it starts a resolve session |
| A push is refused with "main changes only through a pull request" or "Force push refused" | `.husky/pre-push` did it. Push a feature branch and open a pull request with `gh pr create`. For the force-push message, run `git fetch`, merge, push |
| A command, hook or permission blocks you | Read `GUARDRAILS.md`. It names what enforces each guardrail in each CLI |
| A session starts without the backlog or the `make check` result | Read `.agent/session-start.log`, then `PROGRESS.md`, and run `scripts/agent/feature.sh status` and `make check` by hand |
| Two sessions in one checkout block each other | The stop gate cannot tell which session changed the tree. Use separate worktrees: `claude -w`, Copilot `/worktree`, `codex fork --worktree` |

Logs for every node are in `.agent/runs/<id>/` of the main checkout: `implement-<n>.log`, `check-<n>.log`, `red.log`, `review-<n>.md` and `result`.

## 10. Limits to know about

- Every runner session uses your Copilot, Claude or Codex plan. A large feature costs far more than a one-file story.
- The runner was tested end to end in Claude Code, Codex and Copilot CLI on 2026-10-23, in scratch clones with a local remote, including `--parallel 2` in tmux. Only `gh pr create` could not run there.
- Known guardrail gaps are listed in `GUARDRAILS.md`: `git push --no-verify`, Copilot without a permission file, and user-level hooks that bypass Claude deny rules.
- The Blocked and Done card moves and label edits were tested locally, not yet inside GitHub Actions.
- There is no release or deploy step yet. That needs a deploy target and a real database.

## 11. Where to read more

| File | Contents |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | Router: hard rules, commands, Definition of Done, and which file to read for which task |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Layers and what each may reference, request flow, persistence, conventions, test projects |
| [`GUARDRAILS.md`](GUARDRAILS.md) | What enforces each guardrail in each CLI, and the known gaps |
| [`PROGRESS.md`](PROGRESS.md) | Current state and every decision with its reason |
| [`docs/agents/harness.md`](docs/agents/harness.md) | The full design, including how each CLI loads skills and subagents |
| [`docs/agents/backlog.md`](docs/agents/backlog.md) | The `feature_list.json` format and `feature.sh` commands |
| [`docs/agents/add-feature.md`](docs/agents/add-feature.md) | How to add an endpoint, entity or use case |
| [`scripts/agent/run.sh`](scripts/agent/run.sh) | The runner |
