---
name: ship
description: Commit the current work on a feature branch, push it and open a pull request to main. Use only when the user explicitly asks to commit, push, ship or open a pull request.
---

# Ship the work as a pull request

1. Run `make check`. If it does not print `CHECK PASSED`, stop and report the failure.
2. Make sure `PROGRESS.md` describes this change. Update it first if it does not.
3. On `main`, create a branch first: `git switch -c <type>/<short-name>`, with a Conventional Commits type such as `feat`, `fix`, `docs` or `chore`.
4. Read `git status` and stage only the files that belong to this change.
5. Commit with a Conventional Commits subject, `<type>(<scope>): <description>`, with a description of at most 88 characters.
   The commit-msg hook rejects anything else. The pre-commit hook formats staged C# files and runs gitleaks.
   If a hook fails, fix the cause. Never use `--no-verify`.
6. Run `git push -u origin <branch>`. Never push to `main` and never force-push.
7. Run `gh pr create --base main --title "<commit subject>" --body "<what changed, why, and how it was verified>"`. Quote the `CHECK PASSED` line in the body.
   For story work, end the body with `Closes #<n>`, where `<n>` is what `scripts/agent/github-sync.sh issue <id>` prints, so merging closes the story's issue.
8. Report the pull request URL. CI runs `make check`, and branch protection on `main` requires it to pass before merge.
