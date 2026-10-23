# AGENTS.md

ASP.NET Core Web API template (.NET 10, SDK pinned in `global.json`) built with Clean Architecture.
The database is SQLite in memory, so nothing external is needed to build, test, or run it.

## Hard rules
1. Never edit or delete a test to make it pass. Fix the code. Change a test only when the requirement changed, and say so.
2. Never silence analyzers: no `#pragma warning disable`, no `NoWarn`, no severity changes in `.editorconfig`.
3. Add NuGet packages only through `Directory.Packages.props` (central package management), and ask first.
4. Commit, push and open pull requests only when asked. Use Conventional Commits (`.husky/commit-msg` enforces it). Work on a feature branch, push it, and open a PR to `main` with `gh pr create`. Never push to `main` and never force-push (`.husky/pre-push` refuses both).
5. Never edit `feature_list.json` by hand. Use `scripts/agent/feature.sh`.
6. Do not add MediatR, AutoMapper, or EF migrations. Messaging is in-house (`ISender`, `IPublisher`), mapping is by hand, and the schema lives in `DatabaseInitializer.cs`.

## Commands
- `make setup`: first run. Restores tools and packages and installs the git hooks.
- `make check`: the only definition of green. It prints `OK   <step>` as each step passes, then `CHECK PASSED`, or `CHECK FAILED at <step>` with the failing lines and the fix to apply. Each step writes its full output to `.agent/`.
  `setup`, `format`, `clean` and `rename` print `OK   <name>` too, and `rename` prints `RENAME FAILED` with the reason.
- `make format`: fixes formatting and line endings automatically.
- `make rename NAME=<Name>`: renames the template to `<Name>` and replaces the git history with a fresh `git init` (runs `rename.sh`). Commit and push everything first.
- `make run`: starts the API on http://localhost:5001 (Swagger at `/swagger`, health at `/health`).
- Prefer these targets over raw `dotnet` commands.

## Read only what your task needs
| Read | When |
|---|---|
| `ARCHITECTURE.md` | Before you add, move or rename code: layers and what each may reference, request flow, persistence, conventions, test projects |
| `docs/agents/add-feature.md` | Adding an endpoint, entity or use case, layer by layer |
| `docs/agents/backlog.md` | Working a story, or adding stories to `feature_list.json` |
| `GUARDRAILS.md` | A command, hook or permission blocks you, or you change a hook, permission, Codex rule, CI or branch protection |
| `docs/agents/harness.md` | Running or changing `scripts/agent/run.sh`, the GitHub sync, or how each CLI loads skills and subagents |
| `docs/prd/<feature>.md#FR-<n>` | Only the section a story's `prd` field names |

## One story at a time
- `scripts/agent/feature.sh start <id>` before writing code, `show <id>` to read the story, `status` and `waves` for what is open. Do not read the whole `feature_list.json`.
- Touch only what the active story needs: `feature.sh done` refuses files outside its `owns`. Note unrelated problems in `PROGRESS.md` instead of fixing them.
- `feature.sh block <id> "<reason>"` when something outside the repo stops you.
- GitHub issues and the board are a view of `feature_list.json`: change scope there, never only on GitHub.
- Small fixes and questions need no story. The Definition of Done still applies.

## Session routine
- Start: the session-start hook injects the `make check` result, the backlog status and `PROGRESS.md`. If that context is missing, read `PROGRESS.md`, run `scripts/agent/feature.sh status`, then `make check` before editing.
- End: update `PROGRESS.md` (state, decisions with their reasons, next steps), run `make check`, and leave no stray files.

## Definition of Done
- `make check` prints `CHECK PASSED`. Quote that line in your final message. "Should work" is not done.
- New behavior has a test that fails without the change. For a story the runner builds, the first commit holds only the story's tests (files under `tests/`) and they fail on it; the gate checks this.
- Feature work: `scripts/agent/feature.sh done <id>` succeeded.
- `PROGRESS.md` says what changed, why, and what comes next.
- When you finish, a stop hook runs `make check` on any uncommitted change and sends you back with the failing lines if it fails. It also sends you back when files changed during the session but `PROGRESS.md` did not.