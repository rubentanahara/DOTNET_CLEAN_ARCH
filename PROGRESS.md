# Progress

## Current state
- `make check` passes: build, format, all tests, API smoke test.
- Every feature in `feature_list.json` is `passing`. They describe the example code the template ships with.

## In progress
- Nothing.

## Decisions
- 2026-10-21: `AGENTS.md` is the only instruction file. Claude Code, Codex and Copilot all read it natively. There is no `CLAUDE.md`: Claude Code falls back to `AGENTS.md` when none exists, and Copilot would load both.
- 2026-10-21: `feature_list.json` changes only through `scripts/agent/feature.sh`, so a feature becomes `passing` only after its own tests actually ran. `dotnet test --filter` exits 0 when nothing matches, so the script counts the tests that passed.
- 2026-10-21: SQLite in memory keeps the tests and the smoke test free of external services.
- 2026-10-21: The stop hook lives in `.claude/settings.json`, because Copilot CLI runs hooks from that file too. A copy in `.github/hooks/` would run the gate twice. Codex gets its own `.codex/hooks.json`.
- 2026-10-21: The stop gate answers with `{"decision":"block","reason":...}` on stdout and exit 0, the only form Claude Code, Codex and Copilot all accept. Copilot ignores exit code 2 on stop events.
- 2026-10-21: Codex's workspace-write sandbox blocks the local sockets used by MSBuild worker nodes, the test host and the smoke test, so `make check` hangs inside it. `.codex/rules/dotnet.rules` runs those commands outside the sandbox instead of switching the whole sandbox off. Rejected: `danger-full-access`, which would switch the sandbox off for every command.

## Known issues
- `requests/Notes/Notes.http` targets http://localhost:5519 (the IIS Express port), but `make run` serves http://localhost:5001.

## Next steps
1. For a new project: run `./rename.sh <Name>`, then replace the example features in `feature_list.json` with your own.
