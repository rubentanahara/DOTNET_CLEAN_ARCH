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

## Known issues
- `requests/Notes/Notes.http` targets http://localhost:5519 (the IIS Express port), but `make run` serves http://localhost:5001.

## Next steps
1. For a new project: run `./rename.sh <Name>`, then replace the example features in `feature_list.json` with your own.
