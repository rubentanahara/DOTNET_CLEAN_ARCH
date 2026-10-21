# AGENTS.md

ASP.NET Core Web API template (.NET 10, SDK pinned in `global.json`) built with Clean Architecture.
The database is SQLite in memory, so nothing external is needed to build, test, or run it.

## Hard rules
1. Never edit or delete a test to make it pass. Fix the code. Change a test only when the requirement changed, and say so.
2. Never silence analyzers: no `#pragma warning disable`, no `NoWarn`, no severity changes in `.editorconfig`.
3. Add NuGet packages only through `Directory.Packages.props` (central package management), and ask first.
4. Never `git push`. Commit only when asked, using Conventional Commits (`.husky/commit-msg` enforces it).
5. Never edit `feature_list.json` by hand. Use `scripts/agent/feature.sh`.
6. Do not add MediatR, AutoMapper, or EF migrations. Messaging is in-house (`ISender`, `IPublisher`), mapping is by hand, and the schema lives in `DatabaseInitializer.cs`.

## Commands
- `make setup`: first run. Restores tools and packages and installs the git hooks.
- `make check`: the only definition of green. Build (warnings are errors), format check, all tests, API smoke test.
  It prints `CHECK PASSED`, or `CHECK FAILED at <step>` with the failing lines and the fix to apply.
- `make format`: fixes formatting and line endings automatically.
- `make run`: starts the API on http://localhost:5001 (Swagger at `/swagger`, health at `/health`).
- Each step writes its full output to `.agent/` (`build.log`, `lint.log`, `test.log`, `smoke.log`).

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

## Scope: one feature at a time
- `feature_list.json` is the backlog. Each entry has a behavior, a test filter, and a state: `not_started`, `active`, `blocked`, or `passing`.
- `scripts/agent/feature.sh add <id> "<behavior>" "<test filter>"` adds an entry.
- `scripts/agent/feature.sh start <id>` before writing code. It refuses while another feature is active.
- Touch only what the active feature needs. Note unrelated problems in `PROGRESS.md` instead of fixing them.
- `scripts/agent/feature.sh done <id>` marks the feature `passing` only after `make check` passes and its own tests ran and passed.
- `scripts/agent/feature.sh block <id> "<reason>"` when something outside the repo stops you.
- Small fixes and questions do not need an entry. The Definition of Done still applies.

## Definition of Done
- `make check` prints `CHECK PASSED`. Quote that line in your final message. "Should work" is not done.
- New behavior has a test that fails without the change.
- Feature work: `scripts/agent/feature.sh done <id>` succeeded.
- `PROGRESS.md` says what changed, why, and what comes next.
- When you finish, a stop hook runs `make check` on any uncommitted change and sends you back with the failing lines if it fails.

## Session routine
- Start: read `PROGRESS.md`, then `feature_list.json`, then run `make check` to learn the baseline before editing.
- End: update `PROGRESS.md` (state, decisions with their reasons, next steps), run `make check`, and leave no stray files.

## Harness wiring
- Claude Code and Copilot CLI read this file and the stop hook in `.claude/settings.json`. Claude Code also takes its permissions from it.
- Codex reads this file and `.codex/`: trust the project, then approve the stop hook once with `/hooks`.
- CI runs `make check` on every pull request (`.github/workflows/ci.yml`).
- The Copilot cloud agent prepares its environment with `.github/workflows/copilot-setup-steps.yml`.
