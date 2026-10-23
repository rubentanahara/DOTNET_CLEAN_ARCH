---
name: feature
description: Work one backlog feature end to end. Picks or adds it in feature_list.json, builds the slice, passes make check and marks it done. Use to build an endpoint, entity or use case, or to work the next backlog feature.
---

# Work one feature

The user gives a feature id (for example F05), a behavior to build, or nothing.

1. Pick the feature.
   - An id: use it.
   - A behavior that has no entry yet: take the next free id and run
     `scripts/agent/feature.sh add <id> "<behavior>" "FullyQualifiedName~<Feature>EndpointTests"`.
     Write the behavior as outcomes a test can check: routes, status codes, validation rules, what is returned.
   - Nothing: take the first `not_started` entry in `feature_list.json`. If there is none, say so and stop.
2. Run `scripts/agent/feature.sh start <id>`. If another feature is active, stop and report which one.
3. Build the slice by following `docs/agents/add-feature.md`, layer by layer, copying the shape of the Notes files it names.
   Cover the success path and every error the module maps in the tests that the filter selects.
4. Run `make format`, then `make check` until it prints `CHECK PASSED`.
5. Add the feature to `PROGRESS.md` with `<id>` in the text: what changed, why, and what comes next.
6. Run `scripts/agent/feature.sh done <id>`.
7. Report the `CHECK PASSED` line and the evidence `done` printed.
   Commit or open a pull request only when the user asked for it, using the `ship` skill.

If something outside the repo stops you, run `scripts/agent/feature.sh block <id> "<reason>"` and report the reason.
