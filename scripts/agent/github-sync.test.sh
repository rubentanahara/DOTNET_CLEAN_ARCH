#!/usr/bin/env bash
set -uo pipefail

readonly SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
export HARNESS_GITHUB_SYNC=off
failures=0

expect() {
  local description=$1 expected=$2 actual=$3
  [[ "$actual" == *"$expected"* ]] && return
  echo "FAIL: $description"
  echo "  expected to contain: $expected"
  echo "  got:                 $actual"
  failures=$((failures + 1))
}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
cd "$sandbox" && git init -q && mkdir -p scripts/agent
cp "$SCRIPTS_DIR/feature.sh" scripts/agent/
cat > feature_list.json << 'JSON'
{"project_title":"Test","priority_legend":{},"sprints":[{"sprint":1,"goal":"first"}],
 "epics":[{"id":"E1","title":"Epic","sprint":1,"summary":"","stories":[
   {"id":"F01","name":"First","title":"As a user, I want one","area":"backend","priority":"P1","estimate":"XS",
    "acceptance_criteria":["Given a, When b, Then c.","Given d, When e, Then f."],"tasks":["write it"],
    "test_filter":"FullyQualifiedName~One|FullyQualifiedName~Uno","depends_on":[],"owns":["src/One/"],"state":"not_started","evidence":""},
   {"id":"F02","name":"Second","title":"As a user, I want two","area":"backend","priority":"P2","estimate":"S",
    "acceptance_criteria":["Given g, When h, Then i."],"tasks":[],
    "test_filter":"FullyQualifiedName~Two","depends_on":["F01"],"owns":["src/Two/"],"state":"not_started","evidence":""}]}]}
JSON

source "$SCRIPTS_DIR/github-sync.sh"
ISSUES_JSON='{"F01":{"number":5,"labels":["story","priority:P1","area:backend","estimate:XS"]},"F02":{"number":6,"labels":[]},"E1":{"number":4}}'
ON_DEFAULT_BRANCH=false

rendered_body() {
  desired_items | jq -r --arg key "$1" 'select(.key == $key) | .body'
}

for story in F01 F02; do
  expect "$story survives render and parse" "$(story_fields $story)" "$(rendered_body $story | body_fields)"
done

edited=$(rendered_body F01 | sed 's/Given d, When e, Then f\./Given x, When y, Then z./')
expect "an edited criterion is parsed" "Given x, When y, Then z." "$(body_fields <<< "$edited")"

apply_edit F01 story "$(body_fields <<< "$edited")" > /dev/null
expect "an accepted edit reaches feature_list.json" "Given x, When y, Then z." "$(story_fields F01)"
expect "an accepted edit keeps the state" '"not_started"' "$(jq -c '.epics[0].stories[0].state' feature_list.json)"

before=$(cat feature_list.json)
expect "an edit with no criterion is refused" "there is no acceptance criterion" \
  "$(apply_edit F01 story "$(body_fields <<< "$(rendered_body F01 | sed '/^- \[ \]/d')")")"
expect "an edit that depends on itself is refused" "F01 is not another story" \
  "$(apply_edit F01 story "$(jq -c '.depends_on = ["F01"]' <<< "$(story_fields F01)")")"
expect "an edit that makes a cycle is refused" "dependency cycle" \
  "$(apply_edit F01 story "$(jq -c '.depends_on = ["F02"]' <<< "$(story_fields F01)")")"
[[ "$(cat feature_list.json)" == "$before" ]] || { echo "FAIL: a refused edit changed feature_list.json"; failures=$((failures + 1)); }
expect "labels are rendered from the story fields" '["area:backend","estimate:XS","priority:P1"]' "$(desired_labels F01)"
expect "labels on the issue are read back as fields" '{"priority":"P1","area":"backend","estimate":"XS"}' "$(label_fields F01)"
expect "a label change on GitHub only is the GitHub side" github "$(change_side aaa bbb aaa)"
expect "a change on both sides is a conflict" both "$(change_side aaa bbb ccc)"
expect "a repo change only is the repo side" repo "$(change_side aaa aaa ccc)"
expect "equal values are the same" same "$(change_side aaa ccc ccc)"
expect "a marker carries the title and labels hashes" "title=bbb labels=ccc" "$(render_marker aaa bbb ccc)"
expect "a marker part is read back" "bbb" "$(marker_part "$(render_marker aaa bbb ccc)" title)"
expect "a legacy marker has no title part" "" "$(marker_part '<!-- harness-sync sha=aaa -->' title)"

expect "an epic body parses to its summary" '{"summary":"The first epic."}' "$(epic_body_fields <<< $'The first epic.\n\n**Sprint:** 1. Its stories are the sub-issues of this issue.\n\n_Synced_')"
apply_edit E1 epic '{"title":"Renamed epic"}' > /dev/null
expect "an epic title edit reaches feature_list.json" '"Renamed epic"' "$(jq -c '.epics[0].title' feature_list.json)"
expect "an empty epic title is refused" "the epic title is empty" "$(apply_edit E1 epic '{"title":""}')"
apply_edit F02 story '{"name":"Deux"}' > /dev/null
expect "a story rename reaches feature_list.json" '"Deux"' "$(jq -c '.epics[0].stories[1].name' feature_list.json)"

expect "the next story id follows the highest F id" "F03" "$(next_story_id)"

form=$'### Epic\n\nE1\n\n### Name\n\nThird\n\n### Story\n\nAs a user, I want three\n\n### Acceptance criteria\n\n- Given a, When b, Then c.\n- Given d, When e, Then f.\n\n### Test filter\n\nFullyQualifiedName~Three\n\n### Depends on\n\nF01\n\n### Owns\n\n`src/Three/`\n\n### Priority\n\nP2\n\n### Estimate\n\n_No response_\n\n### Area\n\nbackend\n'
fragment=$(form_fragment F03 "$form")
expect "a story form becomes a fragment" '"acceptance_criteria":["Given a, When b, Then c.","Given d, When e, Then f."]' "$fragment"
expect "an unanswered form field is left out" '"priority":"P2"' "$fragment"
expect "the form fragment keeps owns without backticks" '"owns":["src/Three/"]' "$fragment"
[[ "$fragment" != *'"estimate"'* ]] || { echo "FAIL: an unanswered estimate was kept"; failures=$((failures + 1)); }
expect "the fragment is accepted by feature.sh add" "Added 1 story(ies) as not_started: F03" "$(bash scripts/agent/feature.sh add <<< "$fragment")"
expect "a form naming no epic is refused" "New epic" "$(bash scripts/agent/feature.sh add <<< "$(form_fragment F04 "${form/E1/NOPE}")" 2>&1)"

gh() {
  echo "gh $*" >> gh-calls.log
  case "$1 $2" in
    "repo view") echo '{"nameWithOwner":"me/repo","owner":{"login":"me"},"defaultBranchRef":{"name":"main"}}' ;;
    "api user") echo me ;;
    "issue list") echo '[{"number":7,"title":"E1 · Epic","labels":[]},{"number":8,"title":"F01 · First","labels":[{"name":"story"}]},
      {"number":30,"title":"Story: proposed on the form","labels":[{"name":"story"}]},{"number":40,"title":"Crash on startup","labels":[{"name":"bug"}]}]' ;;
    "project list") echo '{"projects":[{"number":14,"title":"Test","closed":false},{"number":3,"title":"Other","closed":false}]}' ;;
  esac
}
deletions() {
  grep -E '^gh (issue|project) delete' gh-calls.log 2> /dev/null | tr '\n' ';'
}
: > gh-calls.log
plan=$(print_reset_plan)
expect "the reset plan lists the epic and story issues" "#7 E1 · Epic" "$plan"
expect "the reset plan lists story-form issues" "#30 Story: proposed on the form" "$plan"
expect "the reset plan lists the project" "project #14 Test" "$plan"
[[ "$plan" != *"#40"* ]] || { echo "FAIL: the reset plan lists an issue the harness does not own"; failures=$((failures + 1)); }
expect "the reset plan deletes nothing" "" "$(deletions)"
expect "the reset plan says how to delete" "github-sync.sh reset --yes" "$plan"
: > gh-calls.log
expect "reset --yes without a terminal is refused" "a person confirms it at a terminal" "$( (delete_github_backlog < /dev/null) 2>&1)"
expect "a refused reset --yes deletes nothing" "" "$(deletions)"
confirm_reset() { :; }
delete_github_backlog > /dev/null
expect "reset --yes deletes the harness issues and the project" \
  "gh issue delete 7 --repo me/repo --yes;gh issue delete 8 --repo me/repo --yes;gh issue delete 30 --repo me/repo --yes;gh project delete 14 --owner @me;" "$(deletions)"
unset -f gh

if (( failures > 0 )); then
  echo "$failures github-sync test(s) failed."
  exit 1
fi
echo "github-sync.sh tests passed."
