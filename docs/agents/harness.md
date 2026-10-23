# Harness design

How this repo lets Claude Code, Codex and Copilot CLI build features reliably, one session at a time today and as an unattended loop next.
It follows *Learn Harness Engineering*: the harness makes a single run reliable, a loop makes runs continuous, and a graph coordinates many loops.
Each section says whether it is **built** or **planned**. Keep this file true: change the status when the code lands, and delete what gets dropped.

## 1. The five subsystems (built)
| Subsystem | Here |
|---|---|
| Instructions | `AGENTS.md` routes to `docs/agents/*.md`. Skills `feature` and `ship` in `.agents/skills/`, copied to `.claude/skills/`. |
| Tools | `make` targets, `scripts/agent/feature.sh`. |
| Environment | `make setup`, `global.json`, SQLite in memory. Nothing external is needed. |
| State | `feature_list.json` (scope and state), `PROGRESS.md` (why and what next), git history. |
| Feedback | `make check`: analyzers as errors, format, unit, architecture and integration tests, API smoke test. Each failure prints its fix. |

Hooks close the loop at both ends: the session-start hook injects state and a fresh `make check`, and the stop hook refuses to stop on a red check or an unchanged `PROGRESS.md`.

## 2. One source of truth, synced with GitHub in near real time (repo to GitHub built, GitHub to repo planned)
The repo is the system of record. GitHub is a live view of it and an inbox for changes, never a second owner of the same field.

| Field | Owner | Flows |
|---|---|---|
| Story scope: `name`, `title`, `acceptance_criteria`, `tasks`, `depends_on`, `owns`, `priority`, `estimate`, `area`, `sprint`, `test_filter` | `feature_list.json`, through `feature.sh add` or a pull request | both ways; GitHub edits arrive as pull requests |
| `state`, `evidence` | `feature.sh`, the verifier. Nobody else moves state. | repo to GitHub only |
| Comments and review discussion | GitHub | stays there; an agent reads it with `gh` when it works the story |

How each change travels:

| Change | Direction | How | Delay | Status |
|---|---|---|---|---|
| `feature.sh start`, `block`, `done` | repo to GitHub | `feature.sh` runs `github-sync.sh push <id>` from any branch or worktree | ~10 s | built |
| Anything in `feature_list.json` | repo to GitHub | `scripts/agent/github-sync.sh push` by hand | ~10 s, ~90 s on the first run | built |
| Merge to `main` | repo to GitHub | an Action on push to `main` runs the same push; `Closes #n` closes the issue | <1 min | planned |
| Issue body edited, story-form issue opened, labels changed, closed or reopened | GitHub to repo | an Action on `issues` events turns the change into a `sync/backlog` pull request that merges itself when green | ~2-4 min | planned |
| Card dragged, board field edited | GitHub to repo | polling: a local watcher every 30 s, a scheduled Action every 15 min | 30 s to 15 min | planned |

`github-sync.sh push` (built):
- One project per repo, found by `project_title`, created and linked on the first full push, with Status options Todo, In Progress, In Review, Blocked, Done, and fields Priority, Estimate, Area and Sprint.
- One issue per epic and per story, titled `<id> · <name>`, stories linked as sub-issues of their epic. Issue numbers are found by title, so the repo stores none.
- Every synced body ends with `<!-- harness-sync sha=... -->`, the hash of the body the sync last wrote. Comparing it with the body on GitHub and the body the repo renders now tells which side changed. A body changed on GitHub is reported and never overwritten; until the inbound sync exists, copy the change into `feature_list.json` or undo it.
- Status: `not_started` Todo, `active` In Progress, `blocked` Blocked, `passing` In Review on a story branch and Done (issue closed) on the default branch. A full push never moves a card from In Progress or In Review back to Todo, because the story may be running on a branch whose state `main` does not have yet.
- A failed push never undoes the state change; `feature.sh` prints how to retry. `HARNESS_GITHUB_SYNC=off` turns the push off, as the harness tests do.

Rules for the planned inbound side:
- A card dragged to In Review or Done is set back with a comment: only `feature.sh done` passes a story.
- A card dragged to Blocked runs `feature.sh block`; from Blocked to Todo runs `feature.sh unblock`.
- Edits from GitHub are accepted only from authors with write access, because the repo is public and issue text reaches agents as instructions.
- The workflows need a `BACKLOG_SYNC_TOKEN` secret (a classic token with `repo` and `project`) and repository auto-merge: the default token cannot reach a user-owned project, and pull requests it opens wait for a person to approve their CI runs.
- GitHub sends no event when a card moves on a user-owned project, so card moves are polled. Rejected: moving the project to an organization for its webhook, which still needs a server to receive it; and letting GitHub own `state`, which would let anyone drag a story to Done and take state out of pull request diffs.

## 3. The story graph (built, `scripts/agent/run.sh`)
`scripts/agent/run.sh [--cli claude|codex|copilot] [--checker <cli>] [--parallel N] [--merge] [--story <id>] [--dry-run]` takes the first line of `feature.sh waves` and runs each story through the same nodes. Each agent node is a fresh headless session named after the story, so the checker never sees the maker's reasoning, and `claude --resume "<name>"` or `copilot --resume` reopens it.

```
claim -> implement -> gate -> review -> done -> ship -> [merge, only with --merge]
            ^           |        |                          |
            +-- fail ---+--------+     conflict -> resolve -+
```

| Node | Kind | Does | On failure |
|---|---|---|---|
| claim | script | worktree `.worktrees/<id>` on branch `feat/<id>-<name>`, from the HEAD the runner started on; `feature.sh start`, which moves the card to In Progress | stop the story |
| implement | agent, `--cli`, session `<id> · <name>` | the `tdd` skill until `make check` passes, and `<id>` in `PROGRESS.md`; may spawn subagents. It does not run `done`, commit or push. | `feature.sh block` ends the story as blocked |
| gate | script | `make check`, `feature.sh scope`, the `PROGRESS.md` mention, the story's tests through its `test_filter` (at least one must pass) | back to implement with the failing lines |
| review | agent, `--checker`, fresh read-only session `<id> · review` | the `verify` skill, reading the test output the gate saved instead of building again; the runner also compares the tree before and after, so a reviewer that edits a file fails | back to implement with the report |
| done | script | `feature.sh done`, which runs `make check` and the tests again and records the evidence; the card moves to In Review | back to implement |
| ship | script | commit `feat(<id>): <name>`, push, pull request with the criteria, the review table, the evidence and `Closes #<n>`; the worktree is removed | stop the story, keep the worktree |
| merge | script, only with `--merge` | waits for CI, updates the branch when it is behind, squash merges, pulls, syncs the board | stop the run |
| resolve | agent, `--cli`, session `<id> · merge <base>` | merges the base into the branch, fixes the conflicts, `make check`; the runner pushes only if the merge is complete and `make check` passes | stop the run |

- Implement, gate and review get 3 attempts per story. After the third failure the story is blocked with the last finding as the reason, and the run goes on with the other stories.
- Merging is opt-in. By default the run stops once the first wave has open pull requests: stories in the next wave need them merged first. `--merge` merges each one once CI is green, then runs the next wave, until nothing is ready.
- The worktree is the checkpoint. A story whose worktree still exists is resumed; one whose worktree holds a blocked state is skipped and named; one with an open pull request is skipped.
- Logs for every node are in `.agent/runs/<id>/` of the main checkout: `implement-<n>.log`, `check-<n>.log`, `review-<n>.md`, `resolve.log` and `result`.
- The runner needs a clean tree. `--merge` also needs the default branch checked out.

## 4. Parallel runs (waves built, runner planned)
- Two stories can run in parallel only when neither depends on the other, they do not change the same files, and neither changes a contract the other relies on.
- `depends_on` covers the first; `owns` covers the other two. `owns` lists the files and directories (ending in `/`) a story may change. `feature.sh waves` puts two stories in the same wave only when their `owns` do not overlap, and says which path kept them apart. A story without `owns` runs alone.
- Files every story touches by design are listed once in the top-level `shared` array and never count as an overlap. `PROGRESS.md` and `feature_list.json` are always allowed.
- `feature.sh done` refuses while the branch changed files outside the story's `owns`; `feature.sh scope <id>` shows them. A story that truly needs another file is blocked with that file named, and a person widens its `owns`.
- `run.sh --parallel N` (planned) runs the stories of one wave at the same time, one worktree and one tmux pane each, the pane titled with the session name. `N=1` is the sequential runner; both are the same code path.
- Merges stay one at a time, because branch protection requires a branch that is up to date with `main`. Without `--merge`, a wave waits until a person merges its pull requests.
- Every slice still edits the same lines of `DatabaseInitializer.cs` and `DependencyInjection.cs`, so they belong in `shared` and conflict on merge. Registering repositories and schema per feature removes that; it is a template change that needs its own decision record.
- Your review bandwidth is the ceiling, not the agent count. Default to `N=1`; raise it for large backlogs of independent stories.

## 5. CLI adapters (built, `run_session` in `scripts/agent/run.sh`)
One case per CLI keeps the graph CLI-agnostic. Adding Cursor or Gemini is two more cases.

| | Writable node | Read-only node | Session name |
|---|---|---|---|
| Claude Code | `claude -p --permission-mode bypassPermissions`, `git commit` and `git push` denied | `claude -p` with `Edit`, `Write`, `make format` and the state-changing `feature.sh` commands denied | `-n` |
| Codex | `codex exec --dangerously-bypass-approvals-and-sandbox` | `codex exec --sandbox read-only -o <file>` | none at launch; the prompt starts with the name |
| Copilot CLI | `copilot -p --allow-all --no-ask-user`, `git commit` and `git push` denied | `copilot -p --deny-tool write` with only read-only `git` and `feature.sh show/scope` allowed | `-n` |

Writable nodes need each CLI's full-permission flag to run unattended. They run only inside a story worktree, the runner itself commits and pushes, and branch protection still rejects pushes to `main`. Codex cannot deny single commands in that mode, so for Codex the prompt is the only thing that keeps it from committing or pushing.

## 6. Roadmap
1. **Backlog primitive (built):** epic and story format, `feature.sh add/show/status/waves`, dependency gate on `start`, harness tests in `make check`, a free smoke-test port.
2. **Repo to GitHub (built):** `github-sync.sh push`, pushed on every state change, three-way body check, `Closes #n` from the `ship` skill.
3. **Parallel safety (built):** `owns`, `shared`, the file-overlap check in `waves`, the scope check in `done`.
4. **GitHub to repo (planned):** the Action on push to `main`, the `issues` Action with sync pull requests, the card watcher, `feature.sh unblock`. Needs `BACKLOG_SYNC_TOKEN` and repository auto-merge.
5. **Skills (built):** `tdd`, `verify`, `prd`, `backlog`.
6. **Runner (built):** the story graph, sequential and `--parallel N` in tmux panes, `--merge` off by default, the three CLI adapters. First real run: F05.
7. **Release and deploy (planned):** release-please, an image on GHCR, staging on every merge, production behind an approval. Blocked on a deploy target and a real database: today's in-memory SQLite and `DROP TABLE` at startup lose all data on restart.
