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
3. Build the slice by following `docs/agents/add-feature.md`, layer by layer, copying the shape of the Notes files it names.
   Each acceptance criterion needs a test that the story's `test_filter` selects.
   You may hand exploration or test writing to subagents. Keep the edits and the final `make check` in this session.
4. Run `make format`, then `make check` until it prints `CHECK PASSED`.
5. Add the story to `PROGRESS.md` with `<id>` in the text: what changed, why, and what comes next.
6. Run `scripts/agent/feature.sh done <id>`.
7. Report the `CHECK PASSED` line and the evidence `done` printed.
   Commit or open a pull request only when the user asked for it, using the `ship` skill.

If something outside the repo stops you, run `scripts/agent/feature.sh block <id> "<reason>"` and report the reason.
