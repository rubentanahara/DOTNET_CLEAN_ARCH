# AGENTS.md

ASP.NET Core Web API template (.NET 10, SDK pinned in `global.json`) built with Clean Architecture.
The database is SQLite in memory, so nothing external is needed to build, test, or run it.

## Hard rules
1. Never edit or delete a test to make it pass. Fix the code. Change a test only when the requirement changed, and say so.
2. Never silence analyzers: no `#pragma warning disable`, no `NoWarn`, no severity changes in `.editorconfig`.
3. Add NuGet packages only through `Directory.Packages.props` (central package management), and ask first.
4. Commit, push and open pull requests only when asked. Use Conventional Commits (`.husky/commit-msg` enforces it). Work on a feature branch, push it, and open a PR to `main` with `gh pr create`. Never push to `main` and never force-push.
5. Never edit `feature_list.json` by hand. Use `scripts/agent/feature.sh`.
6. Do not add MediatR, AutoMapper, or EF migrations. Messaging is in-house (`ISender`, `IPublisher`), mapping is by hand, and the schema lives in `DatabaseInitializer.cs`.

## Commands
- `make setup`: first run. Restores tools and packages and installs the git hooks.
- `make check`: the only definition of green. Hook config, skill copy, harness script tests and unused package checks, build (warnings are errors), format check, all tests, API smoke test.
  It prints `CHECK PASSED`, or `CHECK FAILED at <step>` with the failing lines and the fix to apply.
- `make format`: fixes formatting and line endings automatically.
- `make run`: starts the API on http://localhost:5001 (Swagger at `/swagger`, health at `/health`).
- Each step writes its full output to `.agent/` (`build.log`, `lint.log`, `test.log`, `smoke.log`).
- Prefer these targets over raw `dotnet` commands.

## Layout
| Project | Holds | May reference |
|---|---|---|
| `src/CleanTemplate.Domain` | Entities, `ErrorOr` errors, domain events, under `Models/<Feature>/` | nothing |
| `src/CleanTemplate.Contracts` | HTTP request and response records | nothing |
| `src/CleanTemplate.Application` | Commands, queries, handlers, repository interfaces, under `Features/<Feature>/` | Domain |
| `src/CleanTemplate.Infrastructure` | Dapper repositories under `Dapper/<Feature>/`, persistence under `Common/Persistence/` | Application |
| `src/CleanTemplate.Api` | Carter modules under `Features/<Feature>/`, `Program.cs`, DI wiring | Application, Infrastructure, Contracts |
| `tests/` | Unit (NSubstitute), architecture (NetArchTest), integration (`WebApplicationFactory`) | |

- The reference column is enforced by `tests/CleanTemplate.ArchitectureTests/LayerDependencyTests.cs`. If it fails, move the code, not the rule.
- Namespaces must match folders (IDE0130 fails the build).
- Handlers and domain event handlers register themselves by reflection. Repositories are registered by hand in `src/CleanTemplate.Infrastructure/DependencyInjection.cs`.
- Adding an endpoint, entity, or use case: read `docs/agents/add-feature.md` first. The Notes feature is the reference slice.

## Conventions
- Expected failures are returned as `ErrorOr<T>`, not thrown, and mapped to HTTP status codes in the Carter module.
- Commands, queries, events, and DTOs are `sealed record`s. Services use primary constructors.
- C# files use CRLF and no final newline. Files you create will usually be LF: run `make format` after creating them.
- StyleCop and Sonar analyzers run in every build.

## Scope: one story at a time
- `feature_list.json` is the backlog: sprints, epics, and stories with acceptance criteria, dependencies, a test filter and a state (`not_started`, `active`, `blocked`, `passing`). Format and commands: `docs/agents/backlog.md`.
- `scripts/agent/feature.sh show <id>` prints one story; `status` and `waves` show what is open and what is ready. Do not read the whole file.
- `scripts/agent/feature.sh start <id>` before writing code. It refuses while another story is active or a dependency is not passing.
- Touch only what the active story needs. Note unrelated problems in `PROGRESS.md` instead of fixing them.
- `scripts/agent/feature.sh done <id>` marks the story `passing` only after `PROGRESS.md` mentions `<id>`, `make check` passes, and its own tests ran and passed.
- `scripts/agent/feature.sh block <id> "<reason>"` when something outside the repo stops you.
- `done` also refuses changes outside the story's `owns`. `scripts/agent/feature.sh scope <id>` lists them.
- `start`, `done` and `block` update the story's GitHub issue and board card. `scripts/agent/github-sync.sh push` syncs the whole backlog. GitHub is a view: change scope in `feature_list.json`, never only on GitHub.
- `scripts/agent/run.sh` works the ready stories unattended: a worktree and named session per story, an independent review, then a pull request. `--dry-run` shows the plan. Design and flags: `docs/agents/harness.md`.
- Small fixes and questions do not need an entry. The Definition of Done still applies.

## Definition of Done
- `make check` prints `CHECK PASSED`. Quote that line in your final message. "Should work" is not done.
- New behavior has a test that fails without the change.
- Feature work: `scripts/agent/feature.sh done <id>` succeeded.
- `PROGRESS.md` says what changed, why, and what comes next.
- When you finish, a stop hook runs `make check` on any uncommitted change and sends you back with the failing lines if it fails. It also sends you back when files changed during the session but `PROGRESS.md` did not.

## Session routine
- Start: the session-start hook injects `PROGRESS.md`, the backlog status with the stories ready to start, and a fresh `make check` result. If that context is missing, read `PROGRESS.md`, then `feature_list.json`, then run `make check` before editing.
- End: update `PROGRESS.md` (state, decisions with their reasons, next steps), run `make check`, and leave no stray files.

## Harness wiring
- Claude Code and Copilot CLI read this file and the session-start and stop hooks in `.claude/settings.json`. Claude Code also takes its permissions from it.
- Copilot CLI also reads `.github/hooks/session-kickoff.json`, which submits a first prompt so the session-start hook runs at launch.
- Skills live in `.agents/skills/<name>/SKILL.md`, which Codex and Copilot CLI read, and are copied to `.claude/skills/` for Claude Code. `make check` fails at `skills` when the copies differ. Skills: `prd` (requirements in `docs/prd/`), `backlog` (cut a PRD into stories), `feature`, `tdd` (one acceptance criterion at a time, test first), `verify` (independent read-only review, run by a fresh session or subagent), `ship`, `grilling` (stress-test a plan), `handoff` (summary for the next session, on the clipboard), `prompt-rewrite`. Invoke them with `/<name>` in Claude Code and Copilot CLI, and with `$<name>` in Codex.
- The hooks in `.codex/hooks.json` must match the hooks in `.claude/settings.json`; `make check` fails at `hooks` when they differ. The hook logic lives only in `scripts/agent/`.
- Codex reads this file and `.codex/`: trust the project, then approve the session-start and stop hooks with `/hooks`, again after any change to `.codex/hooks.json`.
  Its sandbox blocks the local sockets `dotnet` needs, so `.codex/rules/dotnet.rules` lets `make`, `dotnet build/test/format` and `feature.sh` run outside it, and forbids pushing to `main` and force-pushing.
- CI runs `make check` on every pull request (`.github/workflows/ci.yml`). Branch protection on `main` requires a pull request and that check to pass, so a direct push to `main` is rejected.
- The Copilot cloud agent prepares its environment with `.github/workflows/copilot-setup-steps.yml`.
