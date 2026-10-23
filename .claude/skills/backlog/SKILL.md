---
name: backlog
description: Cut a PRD or a feature request into epics and stories in feature_list.json through feature.sh add, with Given/When/Then criteria, dependencies, owns and test filters, reviewed for coverage before anything is added. Use when asked to plan a backlog, break a PRD into stories, or add several stories at once.
---

# Cut a backlog

Turn requirements into stories the harness can schedule, run in parallel safely and verify. The format is in `docs/agents/backlog.md`.

## 1. Read
- The PRD in full, or the request. Skip any requirement that waits on an open question, and say which.
- `scripts/agent/feature.sh status` for the existing epics, ids and sprints. New ids continue after the highest one: F05 follows F04.
- The Layout section of `AGENTS.md` and `docs/agents/add-feature.md`. Every story is one vertical slice through those layers.

## 2. Draft the fragment
**Epics:** one per aggregate or feature folder (Consultants, Achievements). Stories of different epics then touch different folders and can run in parallel. Give sprints in dependency order.

**Stories:** one session of work each. A story is one use case end to end, such as one endpoint or one rule ("Submit achievement"), not a layer ("Achievement repository") and not a whole feature ("Achievements").

| Field | Write |
|---|---|
| `name` | Two to four words. It becomes the issue title, the branch and the session name. |
| `title` | "As a <role from the PRD>, I want <goal> so that <reason>." |
| `acceptance_criteria` | Given/When/Then lines a test can check over HTTP: route, status code, response fields. One line for each error the story returns. |
| `prd` | `docs/prd/<feature>.md#FR-<n>`, the requirement the story implements. |
| `depends_on` | Stories whose code this one needs: the entity it extends, the endpoint it calls, the data it reads. Test: could this story's tests pass with only its dependencies merged? If not, a dependency is missing. |
| `owns` | The exact files the story creates or changes, from the slice layout, including its `tests/` class and its `requests/<Feature>/<Feature>.http` file. Name the module, repository interface and entity files explicitly when several stories extend them, so those stories land in different waves. Use a directory (ending in `/`) only for a feature folder no other story touches. Leave out the files in the top-level `shared` list. |
| `test_filter` | `FullyQualifiedName~<StoryTestClass>`, one test class per story, so `feature.sh done` runs exactly its tests. |
| `priority`, `estimate`, `area` | P0 on the critical path to P3 parked; XS to XL; backend, security, architecture or another single word. |

Example story, for a feature folder that F03 created:
```json
{"id": "F04", "name": "Submit achievement", "area": "backend", "priority": "P0", "estimate": "S",
 "title": "As a consultant, I want to submit my draft so that my reviewer sees it.",
 "acceptance_criteria": [
   "Given my draft and I am a Mid or Senior, When I POST /achievements/{id}/submit, Then it returns 200 with status Submitted and my Lead as reviewer.",
   "Given an achievement that is not mine, When I submit it, Then it returns 403.",
   "Given an achievement already submitted, When I submit it again, Then it returns 409."],
 "prd": "docs/prd/achievements.md#FR-4", "depends_on": ["F03"],
 "owns": ["src/CleanTemplate.Application/Features/Achievements/SubmitAchievementCommand.cs",
          "src/CleanTemplate.Application/Features/Achievements/SubmitAchievementCommandHandler.cs",
          "src/CleanTemplate.Application/Features/Achievements/IAchievementsRepository.cs",
          "src/CleanTemplate.Domain/Models/Achievements/Achievement.cs",
          "src/CleanTemplate.Api/Features/Achievements/AchievementsModule.cs",
          "tests/CleanTemplate.Api.IntegrationTests/SubmitAchievementTests.cs"],
 "test_filter": "FullyQualifiedName~SubmitAchievementTests"}
```

A story that needs a person first, such as a new package or a secret, is added like any other and then blocked with `feature.sh block <id> "<what needs approval>"`.

## 3. Review before adding
Give the PRD and the draft fragment to a subagent with a fresh context. Ask it to report, each finding with the requirement or story id:
- Requirements with no story, and stories outside the PRD or listed under Out of scope.
- Criteria that are not Given/When/Then or cannot be checked over HTTP, and errors in the PRD with no criterion.
- Missing dependencies, by the test above, and dependencies on a later sprint.
- `owns` that misses a file the story must change, or claims a directory another story also writes to.

Apply every finding and ask again, until nothing blocking is left.

## 4. Add
1. Run `scripts/agent/feature.sh add < fragment.json`. It validates the whole fragment and adds nothing on an error; fix the fragment and run it again.
2. Show `scripts/agent/feature.sh waves`. It prints on stderr why each story waits.
3. Add a line to `PROGRESS.md` naming the epics added and the first wave.
4. Commit and open a pull request with the `ship` skill only when the user asks. After it merges to `main`, `scripts/agent/github-sync.sh push` creates the issues and board cards. Do not push before the merge, so a rejected backlog leaves no issues behind.
