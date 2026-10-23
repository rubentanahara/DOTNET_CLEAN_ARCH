#!/usr/bin/env bash
set -euo pipefail

readonly FEATURES_FILE=feature_list.json
readonly PROGRESS_FILE=PROGRESS.md
readonly USAGE='Usage:
  scripts/agent/feature.sh add < fragment.json      add epics, stories and sprints (see docs/agents/backlog.md)
  scripts/agent/feature.sh show <id>                print one story with its epic and sprint
  scripts/agent/feature.sh status                   progress per sprint and every story not passing
  scripts/agent/feature.sh waves                    open stories grouped into waves that can run in parallel
  scripts/agent/feature.sh start <id>
  scripts/agent/feature.sh done <id>
  scripts/agent/feature.sh block <id> "<reason>"'

readonly STORIES_JQ='def fail(errors): (errors | join("\n")) + "\n" | halt_error(1);
def stories: [.epics[] | .sprint as $sprint | .id as $epic | .stories[]
  | . + {epic: $epic, sprint: (if has("sprint") then .sprint else $sprint end)}];'

readonly WAVES_JQ="$STORIES_JQ"'
  stories as $all
  | ($all | map(select(.state == "passing") | .id)) as $passing
  | {open: [$all[] | select((.state | IN($open_states[])) and .sprint != null)], skipped: []}
  | until((.open | map(.id)) as $ids | all(.open[]; (.depends_on - $passing - $ids) | length == 0);
      (.open | map(.id)) as $ids
      | [.open[] | select((.depends_on - $passing - $ids) | length > 0)] as $stuck
      | .skipped += [$stuck[] | "\(.id) waits on \((.depends_on - $passing - $ids) | join(", ")), which is blocked, parked, or waiting on one."]
      | .open -= $stuck)
  | .skipped as $skipped
  | .open as $open
  | [$open[] | .sprint as $sprint | .id as $id | .depends_on[] as $dep | $open[] | select(.id == $dep and .sprint > $sprint)
      | "\($id) (sprint \($sprint)) depends on \(.id), which is in later sprint \(.sprint)."] as $late
  | if ($late | length) > 0 then fail($late) else . end
  | {remaining: [$open[] | .sprint as $sprint | . + {after: [$open[] | select(.sprint < $sprint) | .id]}], done: $passing, waves: []}
  | until(.remaining | length == 0;
      .done as $done
      | (.remaining | map(select((.depends_on + .after - $done) | length == 0) | .id)) as $wave
      | if ($wave | length) == 0 then fail(["Dependency cycle among: \(.remaining | map(select((.depends_on - $done) | length > 0) | .id) | join(", "))"]) else . end
      | .waves += [$wave] | .done += $wave
      | .remaining |= map(select(.id as $id | $wave | index($id) | not)))
  | {waves, skipped: $skipped}'
readonly SCHEDULED_STATES='["not_started","active"]'
readonly UNFINISHED_STATES='["not_started","active","blocked"]'

readonly ADD_JQ='
def text: type == "string" and length > 0;
def normalize: {id, name, title, area: (.area // ""), priority: (.priority // "P1"), estimate: (.estimate // ""),
  acceptance_criteria, depends_on: (.depends_on // []), tasks: (.tasks // []), test_filter,
  state: "not_started", evidence: ""} + (if has("sprint") then {sprint} else {} end);
([.epics[].stories[].id]) as $existing
| ([$fragment.epics[]?.stories[]?]) as $new
| ($existing + [$new[].id]) as $ids
| ([$new[] | select((.id | text) and (.name | text) and (.title | text) and (.test_filter | text)
      and (.acceptance_criteria | type == "array" and length > 0) | not) | .id // "a story without id"]
    | map("\(.) needs id, name, title, test_filter and at least one acceptance criterion.")) as $incomplete
| ($ids | group_by(.) | map(select(length > 1) | "\(.[0]) is used more than once.")) as $duplicates
| ([$new[] | .id as $id | (.depends_on // [])[] | select(. as $dep | $ids | index($dep) | not)
      | "\($id) depends on \(.), which does not exist."]) as $unknown
| . as $current
| ([$fragment.epics[]? | select(.id as $id | [$current.epics[].id] | index($id) | not)
      | select(((.title | text) and has("sprint")) | not)
      | "New epic \(.id) needs a title and a sprint (a number, or null to park it)."]) as $untitled
| ($incomplete + $duplicates + $unknown + $untitled) as $errors
| if ($errors | length) > 0 then fail($errors) else . end
| reduce ($fragment.epics // [])[] as $epic (.;
    if any(.epics[]; .id == $epic.id)
    then .epics |= map(if .id == $epic.id then .stories += [$epic.stories[]? | normalize] else . end)
    else .epics += [{id: $epic.id, title: $epic.title, sprint: $epic.sprint, summary: ($epic.summary // ""),
      stories: [$epic.stories[]? | normalize]}]
    end)
| .sprints = ((.sprints + ($fragment.sprints // [])) | unique_by(.sprint))'

fail() {
  echo "$1" >&2
  exit 1
}

story_field() {
  jq -r --arg id "$1" "$STORIES_JQ"' stories[] | select(.id == $id) | .'"$2"' // empty' "$FEATURES_FILE"
}

require_state() {
  local id=$1 allowed=$2 state
  state=$(story_field "$id" state)
  [[ -n "$state" ]] || fail "No story $id in $FEATURES_FILE."
  [[ " $allowed " == *" $state "* ]] || fail "$id is $state. This action needs: $allowed."
}

write_features() {
  local filter=$1
  shift
  jq "$@" "$filter" "$FEATURES_FILE" > "$FEATURES_FILE.tmp"
  mv "$FEATURES_FILE.tmp" "$FEATURES_FILE"
}

set_state() {
  write_features '.epics |= map(.stories |= map(if .id == $id then .state = $state | .evidence = $evidence else . end))' \
    --arg id "$1" --arg state "$2" --arg evidence "$3"
  echo "$1 is now $2."
}

add_from_fragment() {
  local fragment candidate
  fragment=$(cat)
  candidate=$(jq --argjson fragment "$fragment" "$STORIES_JQ$ADD_JQ" "$FEATURES_FILE") || fail "Nothing added."
  jq --argjson open_states "$UNFINISHED_STATES" "$WAVES_JQ" <<< "$candidate" > /dev/null || fail "Nothing added."
  printf '%s\n' "$candidate" > "$FEATURES_FILE.tmp"
  mv "$FEATURES_FILE.tmp" "$FEATURES_FILE"
  jq -r '[.epics[]?.stories[]?.id] as $stories | [.sprints[]?.sprint] as $sprints
    | "Added \($stories | length) story(ies) as not_started\(if ($stories | length) > 0 then ": " + ($stories | join(", ")) else "" end), and \($sprints | length) sprint(s)."' <<< "$fragment"
}

show_story() {
  local story
  story=$(jq --arg id "$1" "$STORIES_JQ"' stories[] | select(.id == $id)' "$FEATURES_FILE")
  [[ -n "$story" ]] || fail "No story $1 in $FEATURES_FILE."
  echo "$story"
}

print_status() {
  jq -r "$STORIES_JQ"'
    stories as $all
    | ($all | map(select(.state == "passing") | .id)) as $passing
    | ((.sprints // []) | map({key: (.sprint | tostring), value: .goal}) | from_entries) as $goals
    | $all | group_by(.sprint == null) | map(group_by(.sprint)[]) | .[]
    | (.[0].sprint | tostring) as $sprint
    | "sprint \(if $sprint == "null" then "parked" else $sprint end)\(if $goals[$sprint] then " (\($goals[$sprint]))" else "" end): \(map(select(.state == "passing")) | length)/\(length) passing",
      (.[] | select(.state != "passing")
        | "  \(.id) [\(.state)] \(.name)\(if (.depends_on - $passing | length) > 0 then " (waits on \(.depends_on - $passing | join(", ")))" else "" end)")
  ' "$FEATURES_FILE"
}

print_waves() {
  local result
  result=$(jq -c --argjson open_states "$SCHEDULED_STATES" "$WAVES_JQ" "$FEATURES_FILE")
  jq -r '.skipped[]' <<< "$result" >&2
  jq -r '.waves[] | join(" ")' <<< "$result"
}

start_story() {
  local id=$1 active unmet
  require_state "$id" "not_started blocked"
  active=$(jq -r "$STORIES_JQ"' [stories[] | select(.state == "active") | .id] | join(", ")' "$FEATURES_FILE")
  [[ -z "$active" ]] || fail "One story at a time: $active is active. Finish it with done or park it with block first."
  unmet=$(jq -r --arg id "$id" "$STORIES_JQ"' stories as $all | ($all[] | select(.id == $id) | .depends_on)
    - [$all[] | select(.state == "passing") | .id] | join(", ")' "$FEATURES_FILE")
  [[ -z "$unmet" ]] || fail "$id depends on $unmet, which is not passing yet."
  set_state "$id" active ""
}

count_passed_tests() {
  { grep -oE 'Passed: +[0-9]+' || true; } | awk '{ total += $2 } END { print total + 0 }'
}

finish_story() {
  local id=$1 test_filter output passed revision
  require_state "$id" "active"
  grep -qwF "$id" "$PROGRESS_FILE" || fail "$PROGRESS_FILE does not mention $id, so it stays active. Add what $id changed, why, and what comes next, then run done again."
  make check || fail "make check failed, so $id stays active. Fix the failures above, then run done again."
  test_filter=$(story_field "$id" test_filter)
  output=$(dotnet test "$(ls ./*.slnx | head -1)" --no-build --filter "$test_filter" 2>&1) || {
    echo "$output" | tail -30 >&2
    fail "Tests for $id failed, so it stays active."
  }
  passed=$(count_passed_tests <<< "$output")
  (( passed > 0 )) || fail "Filter '$test_filter' matched no tests, so $id stays active. Write its tests or fix the filter."
  revision=$(git rev-parse --short HEAD)
  [[ -z "$(git status --porcelain)" ]] || revision="$revision plus uncommitted changes"
  set_state "$id" passing "$passed tests passed on $revision, $(date -u +%Y-%m-%dT%H:%MZ)"
}

block_story() {
  require_state "$1" "not_started active"
  set_state "$1" blocked "$2"
}

cd "$(git rev-parse --show-toplevel)"
command -v jq > /dev/null || fail "jq is required. Install it (brew install jq, or winget install jqlang.jq) and retry."

case "${1:-} $#" in
  "add 1") add_from_fragment ;;
  "show 2") show_story "$2" ;;
  "status 1") print_status ;;
  "waves 1") print_waves ;;
  "start 2") start_story "$2" ;;
  "done 2") finish_story "$2" ;;
  "block 3") block_story "$2" "$3" ;;
  *) fail "$USAGE" ;;
esac
