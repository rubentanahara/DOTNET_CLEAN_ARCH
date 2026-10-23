#!/usr/bin/env bash
set -euo pipefail

readonly FEATURES_FILE=feature_list.json
readonly USAGE='Usage:
  scripts/agent/github-sync.sh push         create or update the project, every epic and story issue, and their board fields
  scripts/agent/github-sync.sh push <id>    update one story or epic (feature.sh runs this after start, block and done)
  scripts/agent/github-sync.sh issue <id>   print the issue number of a story or epic'
readonly MARKER_REGEX='^<!-- harness-sync sha=([0-9a-f]+) -->$'
readonly PLACEHOLDER_BODY='Created by scripts/agent/github-sync.sh. The same run fills this in.'
readonly FOOTER='_Synced from `feature_list.json` by `scripts/agent/github-sync.sh`. Change the story there: edits made here are reported, not applied._'
readonly STATUS_OPTIONS='[{"name":"Todo","color":"GRAY"},{"name":"In Progress","color":"YELLOW"},{"name":"In Review","color":"BLUE"},{"name":"Blocked","color":"RED"},{"name":"Done","color":"GREEN"}]'
readonly ESTIMATE_OPTIONS=XS,S,M,L,XL
readonly SECONDS_BETWEEN_CREATES=1
readonly ISSUE_LIST_LIMIT=1000

main() {
  cd "$(git rev-parse --show-toplevel)"
  command -v gh > /dev/null || fail "gh is required. Install it and run gh auth login."
  case "${1:-} $#" in
    "push 1") push_backlog "" ;;
    "push 2") push_backlog "$2" ;;
    "issue 2") print_issue_number "$2" ;;
    *) fail "$USAGE" ;;
  esac
}

push_backlog() {
  local only=$1
  load_repository
  if [[ -z "$only" ]]; then ensure_project; else require_project; fi
  load_fields
  load_issues
  local keys
  keys=$(selected_keys "$only")
  create_missing_issues "$keys"
  reconcile_issues "$keys"
  link_sub_issues "$keys"
  reconcile_board "$keys" "$only"
}

print_issue_number() {
  load_repository
  load_issues
  local number
  number=$(issue_field "$1" number)
  [[ -n "$number" ]] || fail "No issue titled '$1 · ...' in $REPO. Run scripts/agent/github-sync.sh push first."
  echo "$number"
}

load_repository() {
  local repo_json
  repo_json=$(gh repo view --json nameWithOwner,owner,defaultBranchRef)
  REPO=$(jq -r .nameWithOwner <<< "$repo_json")
  OWNER=$(jq -r .owner.login <<< "$repo_json")
  local default_branch current_branch
  default_branch=$(jq -r .defaultBranchRef.name <<< "$repo_json")
  current_branch=${GITHUB_REF_NAME:-$(git branch --show-current)}
  ON_DEFAULT_BRANCH=false
  [[ "$current_branch" == "$default_branch" ]] && ON_DEFAULT_BRANCH=true
  PROJECT_TITLE=$(jq -r .project_title "$FEATURES_FILE")
}

ensure_project() {
  PROJECT_NUMBER=$(find_project_number)
  if [[ -z "$PROJECT_NUMBER" ]]; then
    PROJECT_NUMBER=$(gh project create --owner "$OWNER" --title "$PROJECT_TITLE" --format json | jq -r .number)
    gh project link "$PROJECT_NUMBER" --owner "$OWNER" --repo "$REPO" > /dev/null
    report "created project #$PROJECT_NUMBER '$PROJECT_TITLE' and linked it to $REPO"
  fi
  PROJECT_ID=$(gh project view "$PROJECT_NUMBER" --owner "$OWNER" --format json | jq -r .id)
  load_fields
  ensure_status_options
  ensure_field Priority SINGLE_SELECT "$(jq -r '.priority_legend | keys | join(",")' "$FEATURES_FILE")"
  ensure_field Estimate SINGLE_SELECT "$ESTIMATE_OPTIONS"
  ensure_field Area TEXT ""
  ensure_field Sprint NUMBER ""
}

require_project() {
  PROJECT_NUMBER=$(find_project_number)
  [[ -n "$PROJECT_NUMBER" ]] || fail "No project '$PROJECT_TITLE' owned by $OWNER. Run scripts/agent/github-sync.sh push to create it."
  PROJECT_ID=$(gh project view "$PROJECT_NUMBER" --owner "$OWNER" --format json | jq -r .id)
}

find_project_number() {
  gh project list --owner "$OWNER" --format json --limit 200 \
    | jq -r --arg title "$PROJECT_TITLE" '[.projects[] | select(.title == $title and (.closed | not)) | .number][0] // empty'
}

load_fields() {
  FIELDS_JSON=$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json --limit 100 | jq '.fields')
}

ensure_field() {
  local name=$1 data_type=$2 options=$3
  [[ -n "$(jq -r --arg name "$name" '.[] | select(.name == $name) | .id' <<< "$FIELDS_JSON")" ]] && return 0
  if [[ "$data_type" == SINGLE_SELECT ]]; then
    gh project field-create "$PROJECT_NUMBER" --owner "$OWNER" --name "$name" --data-type "$data_type" --single-select-options "$options" > /dev/null
  else
    gh project field-create "$PROJECT_NUMBER" --owner "$OWNER" --name "$name" --data-type "$data_type" > /dev/null
  fi
  report "created board field $name"
  load_fields
}

ensure_status_options() {
  local field_id current merged
  field_id=$(jq -r '.[] | select(.name == "Status") | .id' <<< "$FIELDS_JSON")
  [[ -n "$field_id" ]] || fail "The project has no Status field."
  current=$(graphql 'query($f:ID!){node(id:$f){... on ProjectV2SingleSelectField{options{name color description}}}}' \
    "$(jq -n --arg f "$field_id" '{f: $f}')" | jq '[.data.node.options[] | {name, color, description: (.description // "")}]')
  merged=$(jq -n --argjson wanted "$STATUS_OPTIONS" --argjson current "$current" '
    [$wanted[] as $w | ($current | map(select(.name == $w.name))[0]) // ($w + {description: ""})]
    + [$current[] | select(.name as $n | $wanted | map(.name) | index($n) | not)]')
  [[ "$(jq 'length' <<< "$merged")" == "$(jq 'length' <<< "$current")" ]] && return 0
  graphql 'mutation($f:ID!,$o:[ProjectV2SingleSelectFieldOptionInput!]!){updateProjectV2Field(input:{fieldId:$f,singleSelectOptions:$o}){projectV2Field{... on ProjectV2SingleSelectField{id}}}}' \
    "$(jq -n --arg f "$field_id" --argjson o "$merged" '{f: $f, o: $o}')" > /dev/null
  report "set Status options to $(jq -r 'map(.name) | join(", ")' <<< "$merged")"
  load_fields
}

load_issues() {
  ISSUES_JSON=$(gh issue list --repo "$REPO" --state all --limit "$ISSUE_LIST_LIMIT" --json number,title,state,body,id,url \
    | jq 'map(select(.title | test("^[^ ]+ · ")) | . + {key: (.title | capture("^(?<k>[^ ]+) · ").k)}) | INDEX(.key)')
}

issue_field() {
  jq -r --arg key "$1" --arg field "$2" '.[$key][$field] // empty' <<< "$ISSUES_JSON"
}

selected_keys() {
  local only=$1
  jq -r --arg only "$only" '
    [.epics[] | .id as $epic | ($epic, .stories[].id) as $key | {key: $key, epic: $epic}]
    | if $only == "" then .[].key
      else (map(select(.key == $only)) | if length == 0 then error("No story or epic \($only) in feature_list.json.") else . end)
        | (.[0].epic, $only) | select(. != null) end' "$FEATURES_FILE" | awk '!seen[$0]++'
}

create_missing_issues() {
  local key title url
  for key in $1; do
    [[ -n "$(issue_field "$key" number)" ]] && continue
    title=$(desired_items | jq -r --arg key "$key" 'select(.key == $key) | .issue_title')
    url=$(gh issue create --repo "$REPO" --title "$title" --body "$PLACEHOLDER_BODY")
    report "created #${url##*/} $title"
    sleep "$SECONDS_BETWEEN_CREATES"
  done
  load_issues
}

reconcile_issues() {
  local key item
  for key in $1; do
    item=$(desired_items | jq -c --arg key "$key" 'select(.key == $key)')
    reconcile_issue "$key" "$item"
  done
}

reconcile_issue() {
  local key=$1 item=$2 number title body state desired_title desired_body
  number=$(issue_field "$key" number)
  title=$(issue_field "$key" title)
  body=$(issue_field "$key" body)
  state=$(issue_field "$key" state)
  desired_title=$(jq -r .issue_title <<< "$item")
  desired_body=$(jq -r .body <<< "$item")
  [[ "$title" == "$desired_title" ]] || { gh issue edit "$number" --repo "$REPO" --title "$desired_title" > /dev/null; report "renamed #$number to $desired_title"; }
  reconcile_body "$number" "$body" "$desired_body"
  if [[ "$(jq -r .close <<< "$item")" == true && "$state" == OPEN ]]; then
    gh issue close "$number" --repo "$REPO" --reason completed --comment "$(jq -r .close_comment <<< "$item")" > /dev/null
    report "closed #$number: passing on the default branch"
  elif [[ "$(jq -r .close <<< "$item")" == false && "$state" == CLOSED ]]; then
    report "#$number is closed on GitHub but $key is not passing. Not changed; reopen it or finish $key."
  fi
}

reconcile_body() {
  local number=$1 body=$2 desired=$3 last_hash current_hash desired_hash
  last_hash=$(marker_hash "$body")
  current_hash=$(content_without_marker "$body" | content_hash)
  desired_hash=$(content_hash <<< "$desired")
  if [[ -z "$last_hash" ]]; then
    if [[ "$current_hash" != "$(content_hash <<< "$PLACEHOLDER_BODY")" && "$current_hash" != "$(content_hash <<< "")" ]]; then
      report "#$number has a body this script did not write. Not overwritten."
      return 0
    fi
  elif [[ "$current_hash" != "$last_hash" && "$desired_hash" != "$last_hash" ]]; then
    report "#$number changed on GitHub and in feature_list.json since the last sync. Conflict: not overwritten."
    return 0
  elif [[ "$current_hash" != "$last_hash" ]]; then
    report "#$number was edited on GitHub. Not applied to feature_list.json yet; copy the change there or undo it."
    return 0
  elif [[ "$desired_hash" == "$last_hash" ]]; then
    return 0
  fi
  printf '%s\n\n<!-- harness-sync sha=%s -->\n' "$desired" "$desired_hash" | gh issue edit "$number" --repo "$REPO" --body-file - > /dev/null
  report "updated #$number"
}

marker_hash() {
  tr -d '\r' <<< "$1" | sed -nE "s/$MARKER_REGEX/\\1/p" | tail -n 1
}

content_without_marker() {
  tr -d '\r' <<< "$1" | grep -vE "$MARKER_REGEX" || true
}

content_hash() {
  tr -d '\r' | sed -E 's/[[:space:]]+$//' | awk 'NF { while (blank > 0) { print ""; blank-- } print; started = 1; next } started { blank++ }' | git hash-object --stdin
}

link_sub_issues() {
  local epic parent_id linked key
  for epic in $(jq -r '.epics[].id' "$FEATURES_FILE"); do
    grep -qxF "$epic" <<< "$1" || continue
    parent_id=$(issue_field "$epic" id)
    linked=$(graphql 'query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){subIssues(first:100){nodes{number}}}}}' \
      "$(jq -n --arg o "$OWNER" --arg r "${REPO#*/}" --argjson n "$(issue_field "$epic" number)" '{o: $o, r: $r, n: $n}')" \
      | jq -r '.data.repository.issue.subIssues.nodes[].number')
    for key in $(jq -r --arg epic "$epic" '.epics[] | select(.id == $epic) | .stories[].id' "$FEATURES_FILE"); do
      grep -qxF "$key" <<< "$1" || continue
      grep -qxF "$(issue_field "$key" number)" <<< "$linked" && continue
      graphql 'mutation($i:ID!,$s:ID!){addSubIssue(input:{issueId:$i,subIssueId:$s}){issue{number}}}' \
        "$(jq -n --arg i "$parent_id" --arg s "$(issue_field "$key" id)" '{i: $i, s: $s}')" > /dev/null
      report "linked #$(issue_field "$key" number) $key under #$(issue_field "$epic" number) $epic"
    done
  done
}

reconcile_board() {
  local keys=$1 only=$2 items key number item_id card item output
  items=$(board_items)
  for key in $keys; do
    number=$(issue_field "$key" number)
    [[ -n "$(jq -r --argjson n "$number" '.[] | select(.number == $n) | .id' <<< "$items")" ]] && continue
    if output=$(gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$(issue_field "$key" url)" 2>&1); then
      report "added #$number to the board"
    elif [[ "$output" != *"already exists"* ]]; then
      fail "$output"
    fi
  done
  items=$(board_items)
  for key in $keys; do
    number=$(issue_field "$key" number)
    card=$(jq -c --argjson n "$number" '.[] | select(.number == $n)' <<< "$items")
    item_id=$(jq -r .id <<< "$card")
    item=$(desired_items | jq -c --arg key "$key" 'select(.key == $key)')
    set_status "$item_id" "$number" "$(jq -r .status <<< "$item")" "$(jq -r '.status // empty' <<< "$card")" "$only"
    set_field "$item_id" "$number" Priority "$(jq -r '.priority // empty' <<< "$item")" "$(jq -r '.priority // empty' <<< "$card")"
    set_field "$item_id" "$number" Estimate "$(jq -r '.estimate // empty' <<< "$item")" "$(jq -r '.estimate // empty' <<< "$card")"
    set_field "$item_id" "$number" Area "$(jq -r '.area // empty' <<< "$item")" "$(jq -r '.area // empty' <<< "$card")"
    set_field "$item_id" "$number" Sprint "$(jq -r '.sprint // empty' <<< "$item")" "$(jq -r '.sprint // empty' <<< "$card")"
  done
}

board_items() {
  gh project item-list "$PROJECT_NUMBER" --owner "$OWNER" --format json --limit 1000 \
    | jq --arg repo "$REPO" '[.items[] | select(.content.type == "Issue" and .content.repository == $repo) | . + {number: .content.number}]'
}

set_status() {
  local item_id=$1 number=$2 desired=$3 current=$4 only=$5
  [[ "$desired" == "$current" ]] && return 0
  if [[ -z "$only" && "$desired" == Todo && ( "$current" == "In Progress" || "$current" == "In Review" ) ]]; then
    return 0
  fi
  set_field "$item_id" "$number" Status "$desired" "$current"
}

set_field() {
  local item_id=$1 number=$2 name=$3 desired=$4 current=$5 field option_id
  [[ -z "$desired" || "$desired" == "$current" ]] && return 0
  field=$(jq -c --arg name "$name" '.[] | select(.name == $name)' <<< "$FIELDS_JSON")
  [[ -n "$field" ]] || { report "the board has no $name field; run scripts/agent/github-sync.sh push"; return 0; }
  case "$(jq -r .type <<< "$field")" in
    ProjectV2SingleSelectField)
      option_id=$(jq -r --arg value "$desired" '.options[] | select(.name == $value) | .id' <<< "$field")
      [[ -n "$option_id" ]] || { report "#$number: the $name field has no option '$desired'"; return 0; }
      gh project item-edit --id "$item_id" --project-id "$PROJECT_ID" --field-id "$(jq -r .id <<< "$field")" --single-select-option-id "$option_id" > /dev/null ;;
    ProjectV2Field)
      if [[ "$name" == Sprint ]]; then
        gh project item-edit --id "$item_id" --project-id "$PROJECT_ID" --field-id "$(jq -r .id <<< "$field")" --number "$desired" > /dev/null
      else
        gh project item-edit --id "$item_id" --project-id "$PROJECT_ID" --field-id "$(jq -r .id <<< "$field")" --text "$desired" > /dev/null
      fi ;;
    *) report "the $name field has a type this script does not set"; return 0 ;;
  esac
  report "#$number: $name ${current:-(empty)} -> $desired"
}

desired_items() {
  jq -c --argjson numbers "$(jq 'map_values(.number)' <<< "$ISSUES_JSON")" --arg footer "$FOOTER" --argjson on_default "$ON_DEFAULT_BRANCH" '
    def ref($key): if $numbers[$key] then "#\($numbers[$key]) \($key)" else $key end;
    def section($heading; $lines): if ($lines | length) > 0 then ["", "### \($heading)"] + $lines else [] end;
    def checked($done): "- [\(if $done then "x" else " " end)] \(.)";
    def story_status: if .state == "passing" then (if $on_default then "Done" else "In Review" end)
      elif .state == "active" then "In Progress" elif .state == "blocked" then "Blocked" else "Todo" end;
    .epics[] | . as $epic
    | ([.stories[].state] | all(. == "passing")) as $all_passing
    | {key: .id, issue_title: "\(.id) · \(.title)", sprint: .sprint,
       status: (if $all_passing and $on_default then "Done"
                elif any(.stories[]; .state != "not_started") then "In Progress" else "Todo" end),
       close: ($all_passing and $on_default), close_comment: "Every story in \(.id) is passing on the default branch.",
       body: ([.summary, "", "**Sprint:** \(.sprint // "parked"). Its stories are the sub-issues of this issue.", "", $footer] | join("\n"))},
      (.stories[] | (.state == "passing") as $done
       | {key: .id, issue_title: "\(.id) · \(.name)", sprint: (if has("sprint") then .sprint else $epic.sprint end),
          priority, estimate, area, status: story_status,
          close: ($done and $on_default), close_comment: "Passing on the default branch. Evidence: \(.evidence)",
          body: ([.title]
            + section("Acceptance criteria"; [.acceptance_criteria[] | checked($done)])
            + section("Tasks"; [.tasks[] | checked($done)])
            + section("Requirement"; [(.prd // "") | select(. != "") | "- `\(.)`"])
            + section("Depends on"; [.depends_on[] | "- \(ref(.))"])
            + section("Owns"; [(.owns // [])[] | "- `\(.)`"])
            + ["", "### Details", "| Epic | Sprint | Priority | Estimate | Area | Test filter |", "|---|---|---|---|---|---|",
               "| \(ref($epic.id)) | \(if has("sprint") then .sprint else $epic.sprint end // "parked") | \(.priority) | \(.estimate) | \(.area) | `\(.test_filter)` |",
               "", "**State:** `\(.state)`\(if (.evidence // "") != "" then ". Evidence: \(.evidence)" else "" end)", "", $footer]
            | join("\n"))})' "$FEATURES_FILE"
}

graphql() {
  jq -n --arg query "$1" --argjson variables "$2" '{query: $query, variables: $variables}' \
    | gh api graphql -H "GraphQL-Features: sub_issues" --input -
}

report() {
  echo "github-sync: $1"
}

fail() {
  echo "$1" >&2
  exit 1
}

main "$@"
