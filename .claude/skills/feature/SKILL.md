---
name: feature
description: Work one backlog story end to end. Picks or adds it in feature_list.json, builds the slice, passes make check and marks it done. Use to build an endpoint, entity or use case, or to work the next story in the backlog.
---

# Work one feature

The user gives a story id (for example F05), a behavior to build, or nothing.

1. Pick the story.
   - An id: use it.
   - A behavior that has no story yet: add one with `scripts/agent/feature.sh add`, using the next free id and the fragment format in `docs/agents/backlog.md`.
     Write the acceptance criteria as Given/When/Then outcomes a test can check: routes, status codes, validation rules, what is returned.
   - Nothing: take the first id on the first line of `scripts/agent/feature.sh waves`. If it prints nothing, say so and stop.
2. Run `scripts/agent/feature.sh show <id>` and `scripts/agent/feature.sh start <id>`. If start refuses, stop and report why.
   When the story has a `prd` reference such as `docs/prd/tags.md#FR-2`, read only that requirement's section of the PRD.
3. Build the slice with the `tdd` skill, one acceptance criterion at a time, following `docs/agents/add-feature.md` and copying the shape of the Notes files it names.
   Each acceptance criterion needs a test that the story's `test_filter` selects. Change only files in the story's `owns`, plus the `shared` files.
   You may hand exploration or test drafting to subagents. Keep the edits and the final `make check` in this session.
4. Run `make format`, then `make check` until it prints `CHECK PASSED`.
5. Get an independent review: start a subagent with a fresh context that has not seen this conversation, and have it run the `verify` skill for `<id>`.
   If your CLI cannot start one, ask the user to run `/verify <id>` (`$verify <id>` in Codex) in a new session.
   Fix every FAIL it reports, run `make check` again, and repeat. After 3 rounds that still fail, block the story with the open FAILs as the reason.
6. Add the story to `PROGRESS.md` with `<id>` in the text: what changed, why, and what comes next.
7. Run `scripts/agent/feature.sh done <id>`.
8. Report the `CHECK PASSED` line, the `VERIFY: PASS` line and the evidence `done` printed.
   Commit or open a pull request only when the user asked for it, using the `ship` skill.

If something outside the repo stops you, run `scripts/agent/feature.sh block <id> "<reason>"` and report the reason.
