# Backlog: feature_list.json

`feature_list.json` is the backlog and the only source of what needs doing. It uses the same shape as a GitHub Project: sprints, epics, and stories inside epics.
Change it only through `scripts/agent/feature.sh`. The script owns `state` and `evidence`; a story reaches `passing` only after its own tests ran.

## Shape
```json
{
  "project_title": "CleanTemplate",
  "priority_legend": { "P0": "...", "P1": "...", "P2": "...", "P3": "..." },
  "sprints": [{ "sprint": 1, "goal": "...", "outcome": "..." }],
  "epics": [{
    "id": "EPIC-TAGS", "title": "Tags", "sprint": 1, "summary": "...",
    "stories": [{
      "id": "F05",
      "name": "Create tag",
      "title": "As an API client, I want to create a tag so that I can label notes.",
      "area": "backend", "priority": "P0", "estimate": "S",
      "acceptance_criteria": ["Given a valid name, When I POST /tags, Then the API returns 201 and the tag."],
      "depends_on": [], "tasks": [],
      "owns": ["src/CleanTemplate.Api/Features/Tags/", "src/CleanTemplate.Application/Features/Tags/",
               "src/CleanTemplate.Domain/Models/Tags/", "src/CleanTemplate.Infrastructure/Dapper/Tags/",
               "src/CleanTemplate.Contracts/Tags/", "tests/CleanTemplate.Api.IntegrationTests/TagsEndpointTests.cs",
               "requests/Tags/"],
      "test_filter": "FullyQualifiedName~TagsEndpointTests",
      "state": "not_started", "evidence": ""
    }]
  }]
}
```
- A story inherits the sprint of its epic unless it sets its own. `"sprint": null` parks it: it is never scheduled.
- `name` is short. It becomes the session name, the branch name and the GitHub issue title `F05 · Create tag`.
- `acceptance_criteria` are Given/When/Then lines a test can check. `test_filter` selects the tests that prove them.
- `prd` (optional) points at the requirement the story implements, such as `docs/prd/tags.md#FR-2`. An agent working the story reads only that section.
- `owns` lists the files and directories (ending in `/`) the story may change: no wildcards, paths from the repo root. It decides which stories can run in parallel, and `done` refuses changes outside it. Leave it empty and the story runs alone and is not scope-checked.
- The top-level `shared` array lists files every story edits by design, such as `src/CleanTemplate.Infrastructure/DependencyInjection.cs`. They never count as an overlap and are always in scope, like `PROGRESS.md` and `feature_list.json`.
- Size a story so one session can finish it. "Create a tag" is right, "Build tagging" is too broad.

## Commands
| Command | Does |
|---|---|
| `feature.sh add < fragment.json` | Adds epics, stories and sprints. Rejects missing fields, duplicate ids, unknown dependencies, dependencies on a later sprint and cycles, and changes nothing when it rejects. New stories always start `not_started`. |
| `feature.sh show <id>` | Prints one story with its epic and sprint. Read this instead of the whole file. |
| `feature.sh status` | Progress per sprint and every story that is not passing. |
| `feature.sh waves` | Open stories grouped into waves. Stories on one line can run in parallel: no dependency between them and no overlapping `owns`. Each line waits for the lines above, and earlier sprints come first. Stories held up by a blocked or parked story are left out; that and every overlap are explained on stderr. |
| `feature.sh start <id>` | `not_started` or `blocked` to `active`. Refuses while another story is active or a dependency is not passing. |
| `feature.sh done <id>` | `active` to `passing`, after `PROGRESS.md` mentions the id, `make check` passes and the story's own tests pass. |
| `feature.sh scope <id>` | Lists the files changed on this branch that the story does not own. `done` runs the same check. |
| `feature.sh unblock <id>` | Makes a blocked story `not_started` again, so it can run. |
| `feature.sh block <id> "<reason>"` | Parks a story that something outside the repo stops. Stories that depend on it leave the waves until it is unblocked with `start`. |

A fragment for `add` has the same shape as the file. Name an existing epic by `id` to add stories to it; a new epic also needs `title` and `sprint`:
```bash
scripts/agent/feature.sh add <<'JSON'
{"epics": [{"id": "EPIC-TAGS", "title": "Tags", "sprint": 2, "stories": [
  {"id": "F05", "name": "Create tag", "title": "As an API client, I want to create a tag so that I can label notes.",
   "acceptance_criteria": ["Given a valid name, When I POST /tags, Then the API returns 201 and the tag.",
                           "Given a blank name, When I POST /tags, Then the API returns 400."],
   "test_filter": "FullyQualifiedName~TagsEndpointTests"}]}],
 "sprints": [{"sprint": 2, "goal": "Notes can be tagged."}]}
JSON
```
`start`, `done` and `block` also update the story's GitHub issue and board card (`scripts/agent/github-sync.sh`, see `docs/agents/harness.md`). A failed update never undoes the state change.

`add` never edits an existing story or sprint. Changing the scope of one is a human decision: a person edits it in a pull request and says why there. Agents never edit the file by hand.
