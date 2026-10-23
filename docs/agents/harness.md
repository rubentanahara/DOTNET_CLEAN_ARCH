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

## 2. One source of truth (built for the repo, planned for GitHub)
The repo is the system of record. GitHub is a view of it and an inbox for new work, never a second owner of the same field.

| Field | Owner | Flows |
|---|---|---|
| Story scope: `name`, `title`, `acceptance_criteria`, `tasks`, `depends_on`, `priority`, `estimate`, `area`, `sprint`, `test_filter` | `feature_list.json`, through `feature.sh add` or a human pull request | repo to GitHub |
| `state`, `evidence` | `feature.sh`, the verifier. Nobody else moves state. | repo to GitHub Status |
| Live run status: In Progress, In Review | the runner | runner to GitHub Status |
| New work proposed on GitHub: an issue from the story form | the person who opened it | GitHub to repo, as a pull request that runs `feature.sh add` |
| Edits to a synced issue body | GitHub | pulled into a pull request when the repo side did not change, reported as a conflict when both did |
| Comments and review discussion | GitHub | stays there; an agent reads it with `gh` when it works the story |

Sync rules (planned, `scripts/agent/github-sync.sh`):
- One issue per epic and per story, titled `<id> · <name>`. Stories are sub-issues of their epic. Issue numbers are found by title, so the repo stores none.
- Each synced body ends with a hidden marker holding the hash of the body the sync last wrote. That one hash makes the sync three-way: repo changed, GitHub changed, both changed, or neither.
- Status follows `state`: `not_started` is Todo, `active` In Progress, `blocked` Blocked, `passing` Done once the pull request merged. A card dragged by hand is set back and reported, because only the verifier moves state.
- Anything the sync wants to change in `feature_list.json` arrives as a pull request. `main` changes only through pull requests.

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
| review | agent, fresh and read-only, session `<id> · review` | checks the diff against each acceptance criterion with file and line evidence | ship on pass; implement with the review on fail |
| ship | script | commit `feat(<id>): <name>`, push, pull request with `Closes #<issue>`, board In Review | merge |
| merge | script, only with `--merge` | waits for CI, merges `main` into the branch when it is behind, squash merges | done; resolve on conflict; implement on red CI |
| resolve | agent, session `<id> · merge main` | resolves the conflicts, runs `make check`, pushes | merge |

- Merging is opt-in. By default a story ends at ship: its pull request waits, green, for a person to merge it. `run.sh --merge` lets the runner merge each pull request itself once CI is green. Branch protection still rejects anything red.
- Stop conditions are machine checks only: `feature.sh done`, the review verdict, CI, and an attempt cap of 3 per story.
- A blocked story leaves the run; stories that do not depend on it continue.
- Checkpoint: `.agent/runs/<run-id>/<id>.json` after every node, so `run.sh --resume <run-id>` continues a crashed run.
- The maker and the checker can be different CLIs (`--maker claude --checker codex`), which makes the review more independent.

## 4. Parallel runs (planned)
- `run.sh --parallel N` runs the stories of one `feature.sh waves` line at the same time, one worktree and one tmux pane each, the pane titled with the session name. `N=1` is the sequential runner; both are the same code path.
- Merges stay one at a time, because branch protection requires a branch that is up to date with `main`. Without `--merge`, a wave waits until a person merges its pull requests, and the runner picks up the next wave on its next start.
- Every slice edits the same few shared lines (`DatabaseInitializer.cs`, `DependencyInjection.cs`, `PROGRESS.md`), so parallel stories conflict there. The resolve node handles it today. Removing those shared edits (repositories and schema that register themselves per feature) is a code change that needs its own decision record first.
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
2. **GitHub sync:** push, three-way drift check, story issue form, pull requests for inbound changes. Local command first, then a workflow on `issues` events. A workflow needs a `PROJECT_TOKEN` secret, because the default token cannot reach a user-owned project.
3. **Sequential runner:** the story graph with `N=1`, checkpoints, the three CLI adapters.
4. **Parallel runner:** worktrees, tmux panes, merge queue.
5. **Automations:** a nightly run, and an audit that fails CI when a `passing` story's filter matches no test.
