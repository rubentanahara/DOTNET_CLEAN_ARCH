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

## 3. The story graph (planned, `scripts/agent/run.sh`)
Every story runs through the same nodes. Each agent node is a fresh headless session named after the story, so it can be reopened with `--resume` and the checker never sees the maker's reasoning.

```
claim -> implement -> review -> ship -> merge -> done
            ^           |                 |
            +-- fail ---+                 +-- conflict -> resolve -> merge
            +---------------- CI red -----+
```

| Node | Kind | Does | Routes to |
|---|---|---|---|
| claim | script | worktree `.worktrees/<id>` on branch `feat/<id>-<name>`, board In Progress | implement |
| implement | agent, session `<id> · <name>` | the `feature` skill; may spawn subagents to explore or write tests | review when `feature.sh done` passed; block after 3 attempts |
| review | agent, fresh and read-only, session `<id> · review`, the `verify` skill | checks the diff against each acceptance criterion with file and line evidence, ends with `VERIFY: PASS` or `VERIFY: FAIL` | ship on pass; implement with the review on fail |
| ship | script | commit `feat(<id>): <name>`, push, pull request with `Closes #<issue>`, board In Review | merge |
| merge | script, only with `--merge` | waits for CI, merges `main` into the branch when it is behind, squash merges | done; resolve on conflict; implement on red CI |
| resolve | agent, session `<id> · merge main` | resolves the conflicts, runs `make check`, pushes | merge |

- Merging is opt-in. By default a story ends at ship: its pull request waits, green, for a person to merge it. `run.sh --merge` lets the runner merge each pull request itself once CI is green. Branch protection still rejects anything red.
- Stop conditions are machine checks only: `feature.sh done`, the review verdict, CI, and an attempt cap of 3 per story.
- A blocked story leaves the run; stories that do not depend on it continue.
- Checkpoint: `.agent/runs/<run-id>/<id>.json` after every node, so `run.sh --resume <run-id>` continues a crashed run.
- The maker and the checker can be different CLIs (`--maker claude --checker codex`), which makes the review more independent.

## 4. Parallel runs (waves built, runner planned)
- Two stories can run in parallel only when neither depends on the other, they do not change the same files, and neither changes a contract the other relies on.
- `depends_on` covers the first; `owns` covers the other two. `owns` lists the files and directories (ending in `/`) a story may change. `feature.sh waves` puts two stories in the same wave only when their `owns` do not overlap, and says which path kept them apart. A story without `owns` runs alone.
- Files every story touches by design are listed once in the top-level `shared` array and never count as an overlap. `PROGRESS.md` and `feature_list.json` are always allowed.
- `feature.sh done` refuses while the branch changed files outside the story's `owns`; `feature.sh scope <id>` shows them. A story that truly needs another file is blocked with that file named, and a person widens its `owns`.
- `run.sh --parallel N` (planned) runs the stories of one wave at the same time, one worktree and one tmux pane each, the pane titled with the session name. `N=1` is the sequential runner; both are the same code path.
- Merges stay one at a time, because branch protection requires a branch that is up to date with `main`. Without `--merge`, a wave waits until a person merges its pull requests.
- Every slice still edits the same lines of `DatabaseInitializer.cs` and `DependencyInjection.cs`, so they belong in `shared` and conflict on merge. Registering repositories and schema per feature removes that; it is a template change that needs its own decision record.
- Your review bandwidth is the ceiling, not the agent count. Default to `N=1`; raise it for large backlogs of independent stories.

## 5. CLI adapters (planned, `scripts/agent/cli.sh`)
One function per CLI keeps the graph CLI-agnostic. Adding Cursor or Gemini is one more function.

| | Writable node | Read-only node | Session name |
|---|---|---|---|
| Claude Code | `claude -p -n <name>` | `--permission-mode plan` | `-n` |
| Codex | `codex exec` | `--sandbox read-only -o <file>` | none at launch; the prompt starts with the name |
| Copilot CLI | `copilot -p -n <name> --no-ask-user` | only read and `git diff` tools allowed | `-n` |

Unattended writable nodes need each CLI's full-permission flag. They run only inside a story worktree, and GitHub branch protection still blocks pushes to `main`.

## 6. Roadmap
1. **Backlog primitive (built):** epic and story format, `feature.sh add/show/status/waves`, dependency gate on `start`, harness tests in `make check`, a free smoke-test port.
2. **Repo to GitHub (built):** `github-sync.sh push`, pushed on every state change, three-way body check, `Closes #n` from the `ship` skill.
3. **Parallel safety (built):** `owns`, `shared`, the file-overlap check in `waves`, the scope check in `done`.
4. **GitHub to repo (planned):** the Action on push to `main`, the `issues` Action with sync pull requests, the card watcher, `feature.sh unblock`. Needs `BACKLOG_SYNC_TOKEN` and repository auto-merge.
5. **Skills (built):** `tdd`, `verify`, `prd`, `backlog`.
6. **Runner (planned):** the story graph, sequential then parallel, `--merge` off by default, the three CLI adapters.
7. **Release and deploy (planned):** release-please, an image on GHCR, staging on every merge, production behind an approval. Blocked on a deploy target and a real database: today's in-memory SQLite and `DROP TABLE` at startup lose all data on restart.
