#!/usr/bin/env bash
set -euo pipefail

readonly FEATURES_FILE=feature_list.json
readonly PROGRESS_FILE=PROGRESS.md
readonly HARNESS_FILES='["PROGRESS.md","feature_list.json"]'
readonly GITHUB_SYNC_SCRIPT=scripts/agent/github-sync.sh
readonly USAGE='Usage:
  scripts/agent/feature.sh add < fragment.json      add epics, stories and sprints (see docs/agents/backlog.md)
  scripts/agent/feature.sh show <id>                print one story with its epic and sprint
  scripts/agent/feature.sh status                   progress per sprint and every story not passing
  scripts/agent/feature.sh waves                    open stories grouped into waves that can run in parallel
  scripts/agent/feature.sh start <id>
  scripts/agent/feature.sh done <id>
  scripts/agent/feature.sh block <id> "<reason>"
  scripts/agent/feature.sh unblock <id>             make a blocked story startable again
  scripts/agent/feature.sh scope <id>               files changed on this branch that the story does not own'

readonly STORIES_JQ='def fail(errors): (errors | join("\n")) + "\n" | halt_error(1);
def stories: [.epics[] | .sprint as $sprint | .id as $epic | .stories[]
  | . + {epic: $epic, sprint: (if has("sprint") then .sprint else $sprint end)}];
def covers($path): . as $prefix | $prefix == $path or (($prefix | endswith("/")) and ($path | startswith($prefix)));
def overlap($a; $b): [$a[] as $x | $b[] as $y | select(($x | covers($y)) or ($y | covers($x))) | $y];
def claims($shared): [(.owns // [])[] | . as $path | select(any($shared[]; covers($path)) | not)];'

readonly WAVES_JQ="$STORIES_JQ"'
  . as $root
  | stories as $all
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
  | ($root.shared // []) as $shared
  | {remaining: [$open[] | .sprint as $sprint | . + {after: [$open[] | select(.sprint < $sprint) | .id], claims: claims($shared)}],
     done: $passing, waves: [], notes: []}
  | until(.remaining | length == 0;
      .done as $done
      | (.remaining | map(select((.depends_on + .after - $done) | length == 0))) as $ready
      | if ($ready | length) == 0 then fail(["Dependency cycle among: \(.remaining | map(select((.depends_on - $done) | length > 0) | .id) | join(", "))"]) else . end
      | (reduce $ready[] as $story ({picked: [], notes: []};
          [.picked[] | select((.claims | length) == 0 or ($story.claims | length) == 0 or (overlap(.claims; $story.claims) | length) > 0)] as $clashes
          | if (.picked | length) == 0 or ($clashes | length) == 0 then .picked += [$story]
            elif ($story.claims | length) == 0 then .notes += [{id: $story.id, text: "\($story.id) runs alone: it has no owns."}]
            elif ($clashes[0].claims | length) == 0 then .notes += [{id: $story.id, text: "\($story.id) waits for \($clashes[0].id), which has no owns and runs alone."}]
            else .notes += [{id: $story.id, text: "\($story.id) waits for \($clashes[0].id): both own \(overlap($clashes[0].claims; $story.claims)[0])."}]
            end)) as $round
      | ($round.picked | map(.id)) as $wave
      | .waves += [$wave] | .done += $wave | .notes += $round.notes
      | .remaining |= map(select(.id as $id | $wave | index($id) | not)))
  | {waves, skipped: ($skipped + (.notes | unique_by(.id) | map(.text)))}'
readonly SCHEDULED_STATES='["not_started","active"]'
readonly UNFINISHED_STATES='["not_started","active","blocked"]'

readonly ADD_JQ='
def text: type == "string" and length > 0;
def normalize: {id, name, title, area: (.area // ""), priority: (.priority // "P1"), estimate: (.estimate // ""),
  acceptance_criteria, depends_on: (.depends_on // []), tasks: (.tasks // []), owns: (.owns // []), prd: (.prd // ""), test_filter,
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
| def repo_paths: type == "array" and all(.[]; type == "string" and length > 0 and (test("[*?\\[]|^/|(^|/)\\.\\.(/|$)") | not));
  ([$new[] | select((.owns // []) | repo_paths | not)
      | "\(.id) owns must be repo-relative paths without wildcards; end a directory with /."]
   + (if ($fragment.shared // []) | repo_paths then [] else ["shared must be repo-relative paths without wildcards; end a directory with /."] end)) as $bad_paths
| ($incomplete + $duplicates + $unknown + $untitled + $bad_paths) as $errors
| if ($errors | length) > 0 then fail($errors) else . end
| reduce ($fragment.epics // [])[] as $epic (.;
    if any(.epics[]; .id == $epic.id)
    then .epics |= map(if .id == $epic.id then .stories += [$epic.stories[]? | normalize] else . end)
    else .epics += [{id: $epic.id, title: $epic.title, sprint: $epic.sprint, summary: ($epic.summary // ""),
      stories: [$epic.stories[]? | normalize]}]
    end)
| .sprints = ((.sprints + ($fragment.sprints // [])) | unique_by(.sprint))
| if ($fragment.shared // []) | length > 0 then .shared = ((.shared // []) + $fragment.shared | unique) else . end'

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
  push_to_board "$1"
}

push_to_board() {
  [[ "${HARNESS_GITHUB_SYNC:-on}" == off ]] && return 0
  bash "$GITHUB_SYNC_SCRIPT" push "$1" || echo "Board not updated for $1. The state change stands; run $GITHUB_SYNC_SCRIPT push $1 to retry." >&2
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

base_revision() {
  local default_branch
  default_branch=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2> /dev/null || echo main)
  git merge-base HEAD "$default_branch" 2> /dev/null || git rev-parse HEAD
}

changed_files() {
  { git diff --name-only "$(base_revision)"; git ls-files --others --exclude-standard; } | sort -u | jq -R . | jq -s .
}

files_outside_owns() {
  jq -r --arg id "$1" --argjson changed "$(changed_files)" --argjson harness "$HARNESS_FILES" "$STORIES_JQ"'
    ((.shared // []) + $harness) as $always_allowed
    | (stories[] | select(.id == $id) | .owns // []) as $owns
    | if ($owns | length) == 0 then empty
      else $changed[] | . as $file | select(any(($owns + $always_allowed)[]; covers($file)) | not) end' "$FEATURES_FILE"
}

check_scope() {
  local id=$1 outside
  [[ -n "$(story_field "$id" state)" ]] || fail "No story $id in $FEATURES_FILE."
  [[ "$(jq -r --arg id "$id" "$STORIES_JQ"' stories[] | select(.id == $id) | .owns // [] | length' "$FEATURES_FILE")" != 0 ]] \
    || { echo "$id has no owns, so its scope is not checked."; return 0; }
  outside=$(files_outside_owns "$id")
  if [[ -n "$outside" ]]; then
    echo "$id changed files outside its owns:" >&2
    echo "$outside" | sed 's/^/  /' >&2
    fail "Undo those changes, or block $id and say which file it needs, so a person can widen its owns."
  fi
  echo "$id changed only files it owns."
}

count_passed_tests() {
  { grep -oE 'Passed: +[0-9]+' || true; } | awk '{ total += $2 } END { print total + 0 }'
}

finish_story() {
  local id=$1 test_filter output passed revision
  require_state "$id" "active"
  grep -qwF "$id" "$PROGRESS_FILE" || fail "$PROGRESS_FILE does not mention $id, so it stays active. Add what $id changed, why, and what comes next, then run done again."
  check_scope "$id" > /dev/null || exit 1
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

unblock_story() {
  require_state "$1" "blocked"
  set_state "$1" not_started ""
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
  "unblock 2") unblock_story "$2" ;;
  "scope 2") check_scope "$2" ;;
  *) fail "$USAGE" ;;
esac
