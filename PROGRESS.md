# Progress

## Current state
- `make check` passes: hook config, unused packages, build, format, all tests, API smoke test.
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
- 2026-10-22: `scripts/agent/session-start.sh` runs from the `SessionStart` hook in `.claude/settings.json` (Claude Code and Copilot CLI) and `.codex/hooks.json` (Codex). It runs `make check` and injects `PROGRESS.md`, the open features and the `make check` output. Each run appends one line to `.agent/session-start.log` naming the calling CLI (the nearest parent process called `claude`, `copilot` or `codex`) and the last line of `make check`. The hook timeout is 300 seconds because a cold `make check` can take more than 30.
- 2026-10-22: Claude Code runs the session-start hook at launch. Copilot CLI 1.0.103 (github/copilot-cli#2201) and Codex 0.163.0 (openai/codex#15266) run it only when the first prompt is submitted. `.github/hooks/session-kickoff.json` is a Copilot prompt hook that submits a first prompt on every new interactive session, so Copilot runs the hook at launch too. It costs one model turn per new session and does not fire on resume or with `-p`. Codex parses prompt hooks but skips them and has no startup-prompt setting, so the only launch trigger is a first prompt on the command line: a `codex` shell function in the user's own shell config runs `command codex "<prompt>"` with the prompt read from `session-kickoff.json` when it gets no arguments and that file exists. Without that function, Codex runs the hook at the first prompt. Rejected: a launch script in the repo, which does nothing when `codex` is started directly. Rejected: a native copy of the command hook in `.github/hooks/`, which would run the hook, and so `make check`, twice per Copilot session. Rejected: writing the notice to `/dev/tty`, which corrupted Copilot's screen.
- 2026-10-22: Codex validates SessionStart output strictly (`additionalProperties: false`), so the top-level `additionalContext` that Copilot reads made the Codex hook fail. `session-start.sh` leaves that field out when the caller is Codex.
- 2026-10-22: No hook file is read by all three CLIs. `.claude/settings.json` serves Claude Code and Copilot, `.codex/hooks.json` serves Codex, and the logic lives only in `scripts/agent/`. `make hooks`, the first step of `make check`, fails when the `hooks` blocks of the two files differ. Rejected: a symlink, which breaks on Windows checkouts and would hand Codex the `permissions` key. Rejected: a generator script, which is more code than the one `jq` command the failure message prints.
- 2026-10-22: `make packages` fails when `Directory.Packages.props` pins a version that no project references. With transitive pinning off, NuGet ignores such entries, so they go stale without any warning. Removed `Microsoft.Extensions.Configuration.Binder`, `Microsoft.Extensions.Configuration.Abstractions` and `Microsoft.OpenApi`, which still arrive transitively at the versions the build resolved before.
- 2026-10-22: `stop-gate.sh` escapes its JSON by hand instead of using `jq`. Without `jq`, `make check` fails, and a gate built on `jq` would print nothing and let the agent stop, the one case it must block.
- 2026-10-22: The `.http` files under `requests/` target http://localhost:5001, the port `make run` and the `http` launch profile serve.

## Known issues
- None.

## Next steps
1. For a new project: run `./rename.sh <Name>`, then replace the example features in `feature_list.json` with your own.
