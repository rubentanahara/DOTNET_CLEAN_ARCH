---
name: verify
description: Independent, read-only check that a story's code and tests prove every acceptance criterion. Prints a PASS or FAIL table with file and line evidence and ends with a VERIFY line. Use after make check passes and before feature.sh done, in a fresh session or a subagent that did not write the code. Never use it to grade work from the same session.
---

# Verify a story

You did not write this code, and you do not change it. Your job is to find where it falls short of the story, with evidence. A model that grades its own work sees its own reasoning instead of its mistakes, so this always runs in a fresh session or a subagent.

Do not edit tracked files. Building and running tests is allowed; they write only to ignored folders.

## Steps
1. `scripts/agent/feature.sh show <id>`: the acceptance criteria, `owns`, `test_filter` and `state`. The state is `active` while the story is being finished, or `passing` when you are asked to recheck it. If it is `not_started` or `blocked`, report that and stop.
2. Read the change: `git diff $(git merge-base HEAD origin/main)`, plus untracked files from `git status`.
3. `scripts/agent/feature.sh scope <id>`. Any file outside `owns` is a FAIL.
4. Run the story's tests: `make build`, then `dotnet test *.slnx --no-build --filter "<test_filter>"`. A failing or missing test is a FAIL.
5. For each acceptance criterion, find the test that proves it and the code that makes it pass:
   - The test's arrange step sets up the Given, its act step does the When, and its assertion checks the whole Then (status code and body, not just one of them).
   - The assertion is not weaker than the criterion, and its expected value does not repeat the code's own calculation.
   - The code handles the case on the real path, not only in the test setup.
6. Check the repo's hard rules in the diff:
   - No existing test was deleted or weakened (`AGENTS.md` rule 1).
   - No `#pragma warning disable`, `NoWarn` or severity change (rule 2).
   - No new package in `Directory.Packages.props` unless the story says a person approved it (rule 3).
   - No MediatR, AutoMapper or EF migrations (rule 6).
   - Expected failures return `ErrorOr`, and the module maps each error type to its status code.

## Report
Print exactly this shape and nothing after the last line:

```
| # | Acceptance criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Given my draft ... Then 200 and status Submitted | PASS | tests/.../SubmitAchievementTests.cs:24 asserts 200 and Submitted; SubmitAchievementCommandHandler.cs:31 sets the reviewer |
| 2 | ... | FAIL | No test sends a Lead's draft; the handler always picks the Lead (Handler.cs:28) |

Other findings:
- <rule or scope problem, with file:line>, or "None."

VERIFY: PASS
```

The last line is `VERIFY: PASS` only when every criterion passes and there are no other findings. Otherwise it is `VERIFY: FAIL <n> of <m> criteria, <k> other findings`, and each FAIL says what is missing, so the next implement step can act on it without asking.
