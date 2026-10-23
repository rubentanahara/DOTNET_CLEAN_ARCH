# Guardrails

Read this when a command, hook or permission blocks you, or before you change a hook, a permission, a Codex rule, CI or branch protection.
Each guardrail names what enforces it in each CLI, why it exists, and when it can go. The CLI rows were tested on 2026-10-23 with Claude Code 2.1.309, Codex 0.163.0 and Copilot CLI 1.0.103.

## What every CLI gets
| Guardrail | Claude Code | Codex | Copilot CLI | Why | Remove when |
|---|---|---|---|---|---|
| Session-start context: `make check` result, backlog, `PROGRESS.md` | `.claude/settings.json` | `.codex/hooks.json` | `.claude/settings.json`, plus the first prompt from `.github/hooks/session-kickoff.json` | A session starts from the real state, not from memory | never |
| Stop is refused while `make check` fails (3 attempts, then the agent must report the failure) | `.claude/settings.json` | `.codex/hooks.json` | `.claude/settings.json` | "Should work" is not done | never |
| Stop is refused while files changed but `PROGRESS.md` did not | same | same | same | The next session needs to know what changed and why | never |
| Conventional Commits, no secrets in commits | `.husky/commit-msg`, `.husky/pre-commit` (gitleaks); git runs them for every CLI and for people | same | same | Readable history; secrets never reach the remote | never |
| No push to `main`, no push that drops commits already pushed | `.husky/pre-push`; git runs it for every CLI and for people, also on `--dry-run` | same | same | `main` changes only through a pull request, and pushed history stays | never |
| Analyzers, format, layer rules, tests, smoke test | `make check`, required by CI on every pull request | same | same | One definition of green | never |
| Story stays inside its `owns` | `feature.sh done` and the runner gate | same | same | Stories in one wave must not touch the same files | never |
| A story's first commit holds only failing tests | the runner gate (`tdd_commit_order` in `scripts/agent/run.sh`) | same | same | A test that never failed proves nothing | never |
| Independent review cannot change files | read-only flags per CLI (`docs/agents/harness.md` section 5) and a tree fingerprint before and after | same | same | A reviewer that edits grades its own work | never |
| `main` changes only through a reviewed pull request with a green `check` | branch protection on GitHub: pull request required, `check` required, force pushes off, admins included | same | same | The last line when every local guardrail is bypassed | never |

## Where the CLIs differ
| Guardrail | Claude Code | Codex | Copilot CLI |
|---|---|---|---|
| `git push origin main`, `git push --force …` before git runs | denied by `permissions.deny` in `.claude/settings.json` | forbidden by `.codex/rules/dotnet.rules` | nothing in the CLI; `.husky/pre-push` refuses them when git runs |
| Editing `feature_list.json` | denied for the Edit tool only; a shell write still works | nothing local | nothing local |
| Reading `.env` | denied | nothing local | nothing local |
| `make`, `dotnet build/test/format`, `feature.sh`, `github-sync.sh` outside the sandbox | allowed by `permissions.allow` | allowed by `.codex/rules/dotnet.rules`, because the sandbox blocks the local sockets `dotnet` needs | `--allow-all` in the runner; asks otherwise |
| No push from the runner's writable session | `--disallowedTools "Bash(git push *)"` | the prompt only: `--dangerously-bypass-approvals-and-sandbox` cannot deny one command | `--deny-tool 'shell(git push)'` |

The runner pushes for the agent, so a push from inside a session is never needed.

## Known gaps
Each gap was reproduced on 2026-10-23. Fix the gap or keep it listed here.
- `git push -u origin main`, `git push origin HEAD:main`, `git push origin +main` and a bare `git push` on `main` match neither the Claude deny rules nor the Codex rules. `.husky/pre-push` refuses all of them, because it reads the refs git is about to push instead of the command line.
- `git push --no-verify` skips `.husky/pre-push`, and a clone where `make setup` never ran has no git hooks. Branch protection still rejects pushes to `main` on GitHub; nothing on GitHub stops a force push to a feature branch.
- Copilot CLI does not apply the deny rules in `.claude/settings.json`, and the repo has no Copilot permission file, so the git hooks and branch protection are its only push guards.
- A user-level `PreToolUse` hook that rewrites a Bash command and approves it bypasses the Claude deny rules for that command. Seen with `rtk hook claude` and `Bash(rtk *)` in `~/.claude/settings.json`: `git commit` ran although `Bash(git commit *)` was denied, and was denied again with `--setting-sources project,local`.
- Codex loads `.codex/config.toml`, `.codex/rules` and `.codex/hooks.json` only in a trusted project. A git worktree under the trusted checkout is trusted. A separate clone elsewhere runs with read-only defaults, no rules and no hooks.
- Claude Code ignores the project's `permissions.allow` in a folder whose trust dialog was never accepted. Its deny rules still apply.
- Claude Code keeps at most 10,000 characters of a hook's output in context and replaces the rest with a 2 KB preview. `scripts/agent/session-start.sh` cuts its context to 9,000 characters so all three CLIs see all of it.

## Changing a guardrail
- Hook logic lives only in `scripts/agent/`. The hooks in `.codex/hooks.json` must match those in `.claude/settings.json`: `make check` fails at `hooks` when they differ.
- After any change to `.codex/hooks.json`, approve the hooks again in Codex with `/hooks`.
- Never weaken a guardrail to get unblocked: no `--no-verify`, no `#pragma warning disable`, no `NoWarn` (hard rule 2). Fix the cause, or `feature.sh block` the story with the reason.
- Update this file in the same pull request, and retest the changed row in every CLI it names.