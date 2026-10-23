#!/usr/bin/env bash
set -euo pipefail

readonly FEATURES_FILE=feature_list.json
readonly USAGE='Usage:
  scripts/agent/github-sync.sh push         create or update the project, every epic and story issue, and their board fields
  scripts/agent/github-sync.sh push <id>    update one story or epic (feature.sh runs this after start, block and done)
  scripts/agent/github-sync.sh issue <id>   print the issue number of a story or epic
  scripts/agent/github-sync.sh intake       add a story for every new story-form issue from an author with write access
  scripts/agent/github-sync.sh pull         write story edits made on GitHub into feature_list.json (scripts/agent/inbound.sh opens the pull request)
  scripts/agent/github-sync.sh pull-board   turn card moves on the board into feature_list.json changes, or undo them'
readonly FEATURE_SCRIPT=scripts/agent/feature.sh
readonly INVALID_PATH_REGEX='[*?\[]|^/|(^|/)\.\.(/|$)'
readonly BODY_FIELDS_JQ='(gsub("\r"; "") | split("\n")) as $lines
  | def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
  def section($name):
    ($lines | index("### \($name)")) as $start
    | if $start == null then [] else
        $lines[$start + 1:] as $rest
        | ([$rest | to_entries[] | select(.value | test("^(### |_Synced|\\*\\*State)")) | .key] | first // ($rest | length)) as $end
        | $rest[:$end] end;
  def checklist($name): [section($name)[] | capture("^- \\[[ xX]\\] (?<text>.*)$")? | .text | trim];
  def bullets($name): [section($name)[] | select(startswith("- ")) | ltrimstr("- ") | trim];
  (section("Details") | map(select(startswith("|")))) as $table
  | ($table[2] // "" | split("|")) as $row
  | def cell($i): ($row[$i] // "" | trim);
  {title: ($lines[0] | trim),
   acceptance_criteria: checklist("Acceptance criteria"),
   tasks: checklist("Tasks"),
   depends_on: [bullets("Depends on")[] | split(" ") | last],
   owns: [bullets("Owns")[] | ltrimstr("`") | rtrimstr("`")],
   priority: cell(3), estimate: cell(4), area: cell(5),
   test_filter: ($row[6:-1] | join("|") | trim | ltrimstr("`") | rtrimstr("`"))}'
readonly STORY_FIELDS_JQ='.epics[].stories[] | select(.id == $id)
  | {title, acceptance_criteria, tasks: (.tasks // []), depends_on: (.depends_on // []), owns: (.owns // []),
     priority: (.priority // ""), estimate: (.estimate // ""), area: (.area // ""), test_filter}'
readonly FIELD_ERRORS_JQ='[.epics[].stories[].id] as $ids
  | if $kind == "epic" then
      [(.epics[] | select(.id == $id)) + $fields | if (.title | length) == 0 then "the epic title is empty" else empty end] | join("; ")
    else
      ((.epics[].stories[] | select(.id == $id)) + $fields) as $f
      | [if ($f.name | length) == 0 then "the story name is empty" else empty end,
         if ($f.title | length) == 0 then "the story text is empty" else empty end,
         if ($f.acceptance_criteria | length) == 0 then "there is no acceptance criterion" else empty end,
         if ($f.test_filter | length) == 0 then "the test filter is empty" else empty end,
         ($f.depends_on[] | select(. == $id or ($ids | index(.) | not)) | "\(.) is not another story"),
         ($f.owns[] | select(test($invalid_path)) | "\(.) is not a repo-relative path"),
         if ($f.estimate | IN("", "XS", "S", "M", "L", "XL") | not) then "estimate \($f.estimate) is not XS, S, M, L or XL" else empty end]
      | join("; ")
    end'
readonly EPIC_BODY_JQ='(gsub("\r"; "") | split("\n")) as $lines
  | ([$lines | to_entries[] | select(.value | startswith("**Sprint:**")) | .key] | first // ($lines | length)) as $end
  | {summary: ($lines[:$end] | join("\n") | sub("^\\s+"; "") | sub("\\s+$"; ""))}'
readonly FORM_FRAGMENT_JQ='(gsub("\r"; "") | "\n" + .) as $text
  | def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
  def single: trim | if . == "_No response_" then "" else . end;
  def lines: split("\n") | map(sub("^[-*]\\s+"; "") | trim) | map(select(length > 0 and . != "_No response_"));
  ($text | split("\n### ") | .[1:] | map(split("\n") | {key: .[0], value: (.[1:] | join("\n"))}) | from_entries) as $f
  | {epics: [{id: ($f["Epic"] // "" | single), stories: [
      {id: $id, name: ($f["Name"] // "" | single), title: ($f["Story"] // "" | trim),
       acceptance_criteria: ($f["Acceptance criteria"] // "" | lines), test_filter: ($f["Test filter"] // "" | single),
       depends_on: ($f["Depends on"] // "" | lines), owns: ($f["Owns"] // "" | lines | map(ltrimstr("`") | rtrimstr("`"))),
       priority: ($f["Priority"] // "" | single), estimate: ($f["Estimate"] // "" | single), area: ($f["Area"] // "" | single)}
      | with_entries(select(.value != ""))]}]}'
readonly MARKER_REGEX='^<!-- harness-sync sha=([0-9a-f]+)( title=[0-9a-f]+)?( labels=[0-9a-f]+)? -->$'
readonly MANAGED_LABEL_REGEX='^(priority|area|estimate):'
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
    "intake 1") intake_stories ;;
    "pull 1") pull_backlog ;;
    "pull-board 1") pull_board ;;
    *) fail "$USAGE" ;;
  esac
}

push_backlog() {
  local only=$1
  load_repository
  if [[ -z "$only" ]]; then ensure_project; ensure_labels; else require_project; fi
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
  PROJECT_OWNER=$OWNER
  [[ "$(gh api user --jq .login 2> /dev/null)" == "$OWNER" ]] && PROJECT_OWNER=@me
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
    PROJECT_NUMBER=$(gh project create --owner "$PROJECT_OWNER" --title "$PROJECT_TITLE" --format json | jq -r .number)
    gh project link "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --repo "$REPO" > /dev/null
    report "created project #$PROJECT_NUMBER '$PROJECT_TITLE' and linked it to $REPO"
  fi
  PROJECT_ID=$(gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json | jq -r .id)
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
  PROJECT_ID=$(gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json | jq -r .id)
}

find_project_number() {
  gh project list --owner "$PROJECT_OWNER" --format json --limit 200 \
    | jq -r --arg title "$PROJECT_TITLE" '[.projects[] | select(.title == $title and (.closed | not)) | .number][0] // empty'
}

load_fields() {
  FIELDS_JSON=$(gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --limit 100 | jq '.fields')
}

ensure_field() {
  local name=$1 data_type=$2 options=$3
  [[ -n "$(jq -r --arg name "$name" '.[] | select(.name == $name) | .id' <<< "$FIELDS_JSON")" ]] && return 0
  if [[ "$data_type" == SINGLE_SELECT ]]; then
    gh project field-create "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --name "$name" --data-type "$data_type" --single-select-options "$options" > /dev/null
  else
    gh project field-create "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --name "$name" --data-type "$data_type" > /dev/null
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
  ISSUES_JSON=$(gh issue list --repo "$REPO" --state all --limit "$ISSUE_LIST_LIMIT" --json number,title,state,body,id,url,labels \
    | jq 'map(select(.title | test("^[^ ]+ · ")) | . + {key: (.title | capture("^(?<k>[^ ]+) · ").k), labels: [.labels[].name]}) | INDEX(.key)')
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
  local key=$1 item=$2 number title body state desired_title desired_body desired_labels current_labels
  local title_side labels_side written_title written_labels
  number=$(issue_field "$key" number)
  title=$(issue_field "$key" title)
  body=$(issue_field "$key" body)
  state=$(issue_field "$key" state)
  desired_title=$(jq -r .issue_title <<< "$item")
  desired_body=$(jq -r .body <<< "$item")
  desired_labels=$(jq -c '(.labels // []) | sort' <<< "$item")
  current_labels=$(managed_labels "$key")
  title_side=$(change_side "$(marker_part "$body" title)" "$(text_hash "$title")" "$(text_hash "$desired_title")")
  labels_side=$(change_side "$(marker_part "$body" labels)" "$(text_hash "$current_labels")" "$(text_hash "$desired_labels")")
  written_title=$(marker_part "$body" title)
  written_labels=$(marker_part "$body" labels)
  case "$title_side" in
    repo)
      gh issue edit "$number" --repo "$REPO" --title "$desired_title" > /dev/null
      report "renamed #$number to $desired_title"
      written_title=$(text_hash "$desired_title") ;;
    same) written_title=$(text_hash "$desired_title") ;;
    github) report "#$number was renamed on GitHub. Not applied yet: scripts/agent/github-sync.sh pull writes it into feature_list.json." ;;
    both) report "#$number was renamed on GitHub and in feature_list.json since the last sync. Conflict: not changed." ;;
  esac
  case "$labels_side" in
    repo)
      set_labels "$number" "$current_labels" "$desired_labels"
      written_labels=$(text_hash "$desired_labels") ;;
    same) written_labels=$(text_hash "$desired_labels") ;;
    github) report "#$number labels were changed on GitHub. Not applied yet: scripts/agent/github-sync.sh pull writes them into feature_list.json." ;;
    both) report "#$number labels were changed on GitHub and in feature_list.json since the last sync. Conflict: not changed." ;;
  esac
  reconcile_body "$key" "$number" "$body" "$desired_body" "$written_title" "$written_labels"
  if [[ "$(jq -r .close <<< "$item")" == true && "$state" == OPEN ]]; then
    gh issue close "$number" --repo "$REPO" --reason completed --comment "$(jq -r .close_comment <<< "$item")" > /dev/null
    report "closed #$number: passing on the default branch"
  elif [[ "$(jq -r .close <<< "$item")" == false && "$state" == CLOSED ]]; then
    report "#$number is closed on GitHub but $key is not passing. Not changed; reopen it or finish $key."
  fi
}

reconcile_body() {
  local key=$1 number=$2 body=$3 desired=$4 title_hash=$5 labels_hash=$6 last_hash current_hash desired_hash marker
  last_hash=$(marker_hash "$body")
  current_hash=$(content_without_marker "$body" | content_hash)
  desired_hash=$(content_hash <<< "$desired")
  marker=$(render_marker "$desired_hash" "$title_hash" "$labels_hash")
  if [[ -z "$last_hash" ]]; then
    if [[ "$current_hash" != "$(content_hash <<< "$PLACEHOLDER_BODY")" && "$current_hash" != "$(content_hash <<< "")" ]]; then
      report "#$number has a body this script did not write. Not overwritten."
      return 0
    fi
  elif [[ "$current_hash" != "$last_hash" && "$desired_hash" != "$last_hash" ]] && body_matches "$key" "$body"; then
    :
  elif [[ "$current_hash" != "$last_hash" && "$desired_hash" != "$last_hash" ]]; then
    report "#$number changed on GitHub and in feature_list.json since the last sync. Conflict: not overwritten."
    return 0
  elif [[ "$current_hash" != "$last_hash" ]]; then
    report "#$number was edited on GitHub. Not applied yet: scripts/agent/github-sync.sh pull writes it into feature_list.json."
    return 0
  elif [[ "$desired_hash" == "$last_hash" && "$(marker_line "$body")" == "$marker" ]]; then
    return 0
  fi
  printf '%s\n\n%s\n' "$desired" "$marker" | gh issue edit "$number" --repo "$REPO" --body-file - > /dev/null
  report "updated #$number"
}

change_side() {
  local last=$1 current=$2 desired=$3
  if [[ "$current" == "$desired" ]]; then
    echo same
  elif [[ -z "$last" || "$current" == "$last" ]]; then
    echo repo
  elif [[ "$desired" == "$last" ]]; then
    echo github
  else
    echo both
  fi
}

text_hash() {
  printf '%s' "$1" | git hash-object --stdin
}

render_marker() {
  local marker="<!-- harness-sync sha=$1"
  [[ -z "$2" ]] || marker="$marker title=$2"
  [[ -z "$3" ]] || marker="$marker labels=$3"
  echo "$marker -->"
}

marker_line() {
  tr -d '\r' <<< "$1" | grep -E "$MARKER_REGEX" | tail -n 1 || true
}

marker_part() {
  local regex
  case "$2" in
    title) regex='s/^<!-- harness-sync sha=[0-9a-f]+( title=([0-9a-f]+))?( labels=[0-9a-f]+)? -->$/\2/p' ;;
    labels) regex='s/^<!-- harness-sync sha=[0-9a-f]+( title=[0-9a-f]+)?( labels=([0-9a-f]+))? -->$/\3/p' ;;
  esac
  tr -d '\r' <<< "$1" | sed -nE "$regex" | tail -n 1
}

managed_labels() {
  jq -c --arg key "$1" --arg managed "$MANAGED_LABEL_REGEX" '(.[$key].labels // []) | map(select(test($managed))) | sort' <<< "$ISSUES_JSON"
}

set_labels() {
  local number=$1 current=$2 desired=$3 add remove label
  while IFS= read -r label <&3; do
    gh label create "$label" --repo "$REPO" --force > /dev/null
  done 3< <(jq -r --argjson c "$current" --argjson d "$desired" '$d - $c | .[]' <<< null)
  add=$(jq -r --argjson c "$current" --argjson d "$desired" '$d - $c | join(",")' <<< null)
  remove=$(jq -r --argjson c "$current" --argjson d "$desired" '$c - $d | join(",")' <<< null)
  if [[ -n "$add" ]]; then
    gh issue edit "$number" --repo "$REPO" --add-label "$add" > /dev/null
  fi
  if [[ -n "$remove" ]]; then
    gh issue edit "$number" --repo "$REPO" --remove-label "$remove" > /dev/null
  fi
  report "#$number labels now $desired"
}

body_fields() {
  jq -R -s -c "$BODY_FIELDS_JQ"
}

epic_body_fields() {
  jq -R -s -c "$EPIC_BODY_JQ"
}

story_fields() {
  jq -c --arg id "$1" "$STORY_FIELDS_JQ" "$FEATURES_FILE"
}

epic_fields() {
  jq -c --arg id "$1" '.epics[] | select(.id == $id) | {summary: ((.summary // "") | sub("^\\s+"; "") | sub("\\s+$"; ""))}' "$FEATURES_FILE"
}

item_kind() {
  if [[ -n "$(story_fields "$1")" ]]; then echo story; else echo epic; fi
}

body_item_fields() {
  if [[ "$(item_kind "$1")" == story ]]; then body_fields <<< "$2"; else epic_body_fields <<< "$2"; fi
}

body_matches() {
  local repo
  if [[ "$(item_kind "$1")" == story ]]; then repo=$(story_fields "$1"); else repo=$(epic_fields "$1"); fi
  [[ -n "$repo" && "$repo" == "$(body_item_fields "$1" "$2")" ]]
}

item_ids() {
  jq -r '.epics[] | "\(.id) epic", (.stories[] | "\(.id) story")' "$FEATURES_FILE"
}

story_ids() {
  jq -r '.epics[].stories[] | "\(.id) \(.state)"' "$FEATURES_FILE"
}

desired_field() {
  desired_items | jq -r --arg key "$1" --arg field "$2" 'select(.key == $key) | .[$field]'
}

desired_labels() {
  desired_items | jq -c --arg key "$1" 'select(.key == $key) | (.labels // []) | sort'
}

label_fields() {
  jq -c --arg key "$1" --arg managed "$MANAGED_LABEL_REGEX" '
    reduce ((.[$key].labels // [])[] | select(test($managed)) | capture("^(?<field>[a-z]+):(?<value>.*)$")) as $label
      ({}; .[$label.field] = $label.value)' <<< "$ISSUES_JSON"
}

pull_backlog() {
  load_repository
  load_issues
  local key kind edits
  while read -r key kind <&3; do
    edits=$(issue_edits "$key" "$kind")
    [[ "$edits" != "{}" ]] || continue
    apply_edit "$key" "$kind" "$edits"
  done 3< <(item_ids)
}

issue_edits() {
  local key=$1 kind=$2 body edits='{}' last_hash current_hash desired_hash title title_side labels_side
  body=$(issue_field "$key" body)
  last_hash=$(marker_hash "$body")
  if [[ -z "$last_hash" ]]; then
    echo '{}'
    return 0
  fi
  current_hash=$(content_without_marker "$body" | content_hash)
  if [[ "$current_hash" != "$last_hash" ]] && ! body_matches "$key" "$body"; then
    desired_hash=$(desired_field "$key" body | content_hash)
    if [[ "$desired_hash" == "$last_hash" ]]; then
      edits=$(body_item_fields "$key" "$(content_without_marker "$body")")
    else
      report "$key changed on GitHub and in feature_list.json since the last sync. Conflict: not applied." >&2
    fi
  fi
  title=$(issue_field "$key" title)
  title_side=$(change_side "$(marker_part "$body" title)" "$(text_hash "$title")" "$(text_hash "$(desired_field "$key" issue_title)")")
  if [[ "$title_side" == github ]]; then
    if [[ "$title" == "$key · "?* ]]; then
      edits=$(jq -c --arg name "${title#* · }" --arg field "$([[ "$kind" == story ]] && echo name || echo title)" '. + {($field): $name}' <<< "$edits")
    else
      report "$key: the title on GitHub must start with '$key · '. Not applied." >&2
    fi
  fi
  if [[ "$kind" == story ]]; then
    labels_side=$(change_side "$(marker_part "$body" labels)" "$(text_hash "$(managed_labels "$key")")" "$(text_hash "$(desired_labels "$key")")")
    if [[ "$labels_side" == github ]]; then
      edits=$(jq -c --argjson labels "$(label_fields "$key")" '. + $labels' <<< "$edits")
    fi
  fi
  echo "$edits"
}

apply_edit() {
  local key=$1 kind=$2 fields=$3 errors backup
  errors=$(jq -r --arg kind "$kind" --arg id "$key" --argjson fields "$fields" --arg invalid_path "$INVALID_PATH_REGEX" "$FIELD_ERRORS_JQ" "$FEATURES_FILE")
  if [[ -n "$errors" ]]; then
    report "$key: the edit on GitHub is not applied: $errors."
    return 0
  fi
  backup=$(cat "$FEATURES_FILE")
  if [[ "$kind" == story ]]; then
    jq --arg id "$key" --argjson fields "$fields" '.epics |= map(.stories |= map(if .id == $id then . + $fields else . end))' "$FEATURES_FILE" > "$FEATURES_FILE.tmp"
  else
    jq --arg id "$key" --argjson fields "$fields" '.epics |= map(if .id == $id then . + $fields else . end)' "$FEATURES_FILE" > "$FEATURES_FILE.tmp"
  fi
  mv "$FEATURES_FILE.tmp" "$FEATURES_FILE"
  if ! bash "$FEATURE_SCRIPT" waves > /dev/null 2>&1; then
    printf '%s\n' "$backup" > "$FEATURES_FILE"
    report "$key: the edit on GitHub breaks the backlog (dependency cycle or a dependency on a later sprint). Not applied."
    return 0
  fi
  report "$key: applied the edit made on GitHub to $FEATURES_FILE"
}

intake_stories() {
  load_repository
  local issue number association id fragment errors
  while read -r issue <&3; do
    number=$(jq -r .number <<< "$issue")
    association=$(jq -r .authorAssociation <<< "$issue")
    case "$association" in
      OWNER | MEMBER | COLLABORATOR) ;;
      *) report "#$number: not read, its author has no write access."; continue ;;
    esac
    id=$(next_story_id)
    fragment=$(form_fragment "$id" "$(jq -r .body <<< "$issue")")
    if errors=$(bash "$FEATURE_SCRIPT" add <<< "$fragment" 2>&1); then
      adopt_story "$number" "$id"
    else
      reject_story "$number" "$errors"
    fi
  done 3< <(gh api --paginate "repos/$REPO/issues?state=open&labels=story&per_page=100" \
    | jq -c '.[] | select(has("pull_request") | not) | {number, title, body, authorAssociation: .author_association, labels}
      | select(.title | test("^[^ ]+ · ") | not) | select([.labels[].name] | index("rejected") | not)')
}

next_story_id() {
  jq -r '[.epics[].stories[].id | select(test("^F[0-9]+$")) | ltrimstr("F") | tonumber] | ((max // 0) + 1) | tostring
    | if length < 2 then "0" + . else . end | "F" + .' "$FEATURES_FILE"
}

form_fragment() {
  jq -R -s -c --arg id "$1" "$FORM_FRAGMENT_JQ" <<< "$2"
}

adopt_story() {
  local number=$1 id=$2 name
  name=$(jq -r --arg id "$id" '.epics[].stories[] | select(.id == $id) | .name' "$FEATURES_FILE")
  gh issue edit "$number" --repo "$REPO" --title "$id · $name" --body "$PLACEHOLDER_BODY" > /dev/null
  load_issues
  reconcile_issue "$id" "$(desired_items | jq -c --arg key "$id" 'select(.key == $key)')"
  report "#$number is now story $id"
}

reject_story() {
  local number=$1 errors=$2
  gh label create rejected --repo "$REPO" --color B60205 --force > /dev/null
  gh issue edit "$number" --repo "$REPO" --add-label rejected > /dev/null
  gh issue comment "$number" --repo "$REPO" --body "This story was not added to the backlog:

\`\`\`
$errors
\`\`\`
Edit the issue, then remove the \`rejected\` label to try again." > /dev/null
  report "#$number was not added: $errors"
}

ensure_labels() {
  gh label create story --repo "$REPO" --color 0E8A16 --description "A story proposed on GitHub" --force > /dev/null
  gh label create rejected --repo "$REPO" --color B60205 --description "The backlog refused this story" --force > /dev/null
}

pull_board() {
  load_repository
  require_project
  load_fields
  load_issues
  local items open_pull_requests id state number card status
  items=$(board_items)
  open_pull_requests=$(gh pr list --repo "$REPO" --state open --json body --jq '[.[].body] | join("\n")')
  while read -r id state <&3; do
    number=$(issue_field "$id" number)
    card=$([[ -n "$number" ]] && jq -c --argjson n "$number" '.[] | select(.number == $n)' <<< "$items")
    [[ -n "$card" ]] || continue
    status=$(jq -r '.status // empty' <<< "$card")
    case "$status:$state" in
      Blocked:not_started | Blocked:active) HARNESS_GITHUB_SYNC=off bash "$FEATURE_SCRIPT" block "$id" "Moved to Blocked on the board." ;;
      Todo:blocked) HARNESS_GITHUB_SYNC=off bash "$FEATURE_SCRIPT" unblock "$id" ;;
      Done:passing) ;;
      Done:* | "In Review":not_started | "In Review":active | "In Review":blocked)
        if [[ "$status" == Done ]] || ! has_pull_request "$id" "$number" "$open_pull_requests"; then
          undo_card_move "$id" "$number" "$(jq -r .id <<< "$card")" "$status"
        fi ;;
    esac
  done 3< <(story_ids)
}

has_pull_request() {
  local id=$1 number=$2 open_pull_requests=$3
  grep -qE "Closes #$number([^0-9]|$)" <<< "$open_pull_requests" \
    || [[ -n "$(git ls-remote --heads origin "feat/$(tr '[:upper:]' '[:lower:]' <<< "$id")-*")" ]]
}

undo_card_move() {
  local id=$1 number=$2 item_id=$3 moved_to=$4 desired
  desired=$(desired_field "$id" status)
  set_status "$item_id" "$number" "$desired" "$moved_to" "$id"
  gh issue comment "$number" --repo "$REPO" --body "Only \`feature.sh done\` passes a story, so the card is back in $desired. Do not move a card to $moved_to by hand." > /dev/null
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
    if output=$(gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$(issue_field "$key" url)" 2>&1); then
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
  gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --limit 1000 \
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
    def tag($field): (.[$field] // "") | select(. != "") | "\($field):\(.)";
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
          labels: ([tag("priority"), tag("estimate"), tag("area")] | sort),
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
