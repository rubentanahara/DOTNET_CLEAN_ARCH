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
ISSUES_JSON='{"F01":{"number":5},"F02":{"number":6}}'
ON_DEFAULT_BRANCH=false

rendered_body() {
  desired_items | jq -r --arg key "$1" 'select(.key == $key) | .body'
}

for story in F01 F02; do
  expect "$story survives render and parse" "$(story_fields $story)" "$(rendered_body $story | body_fields)"
done

edited=$(rendered_body F01 | sed 's/Given d, When e, Then f\./Given x, When y, Then z./')
expect "an edited criterion is parsed" "Given x, When y, Then z." "$(body_fields <<< "$edited")"

apply_edit F01 "$(body_fields <<< "$edited")" > /dev/null
expect "an accepted edit reaches feature_list.json" "Given x, When y, Then z." "$(story_fields F01)"
expect "an accepted edit keeps the state" '"not_started"' "$(jq -c '.epics[0].stories[0].state' feature_list.json)"

before=$(cat feature_list.json)
expect "an edit with no criterion is refused" "there is no acceptance criterion" \
  "$(apply_edit F01 "$(body_fields <<< "$(rendered_body F01 | sed '/^- \[ \]/d')")")"
expect "an edit that depends on itself is refused" "F01 is not another story" \
  "$(apply_edit F01 "$(jq -c '.depends_on = ["F01"]' <<< "$(story_fields F01)")")"
expect "an edit that makes a cycle is refused" "dependency cycle" \
  "$(apply_edit F01 "$(jq -c '.depends_on = ["F02"]' <<< "$(story_fields F01)")")"
[[ "$(cat feature_list.json)" == "$before" ]] || { echo "FAIL: a refused edit changed feature_list.json"; failures=$((failures + 1)); }

if (( failures > 0 )); then
  echo "$failures github-sync test(s) failed."
  exit 1
fi
echo "github-sync.sh tests passed."
