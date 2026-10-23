#!/usr/bin/env bash
set -uo pipefail

readonly FEATURE_SCRIPT="$(cd "$(dirname "$0")" && pwd)/feature.sh"
export HARNESS_GITHUB_SYNC=off
failures=0

feature() {
  bash "$FEATURE_SCRIPT" "$@" 2>&1
}

expect() {
  local description=$1 expected=$2 actual=$3
  if [[ "$actual" == *"$expected"* ]]; then return; fi
  echo "FAIL: $description"
  echo "  expected to contain: $expected"
  echo "  got: $actual"
  failures=$((failures + 1))
}

expect_unchanged() {
  local description=$1 before=$2
  [[ "$(cat feature_list.json)" == "$before" ]] && return
  echo "FAIL: $description changed feature_list.json"
  failures=$((failures + 1))
}

story() {
  printf '{"id":"%s","name":"Story %s","title":"As a user, I want %s","acceptance_criteria":["Given, When, Then"],"test_filter":"FullyQualifiedName~%s","depends_on":%s,"state":"%s","evidence":"","owns":%s%s}' \
    "$1" "$1" "$1" "$1" "$2" "$3" "${5:-[\"src/$1/\"]}" "${4:+,\"sprint\":$4}"
}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
cd "$sandbox" && git init -q

cat > feature_list.json << JSON
{"project_title":"Test","priority_legend":{},
 "sprints":[{"sprint":1,"goal":"first"},{"sprint":2,"goal":"second"}],
 "epics":[{"id":"E1","title":"Epic one","sprint":1,"summary":"","stories":[
   $(story A '[]' passing),
   $(story B '["A"]' not_started),
   $(story C '[]' not_started),
   $(story D '[]' not_started 2)]}]}
JSON

expect "waves run sprint 1 before sprint 2" $'B C\nD' "$(feature waves)"
expect "show adds the epic and sprint" '"epic": "E1"' "$(feature show C)"

before=$(cat feature_list.json)
expect "add rejects a story without criteria" "X needs id, name, title, test_filter" \
  "$(feature add <<< '{"epics":[{"id":"E1","stories":[{"id":"X","name":"x","title":"x","test_filter":"x"}]}]}')"
expect "add rejects a duplicate id" "C is used more than once" \
  "$(feature add <<< "{\"epics\":[{\"id\":\"E1\",\"stories\":[$(story C '[]' not_started)]}]}")"
expect "add rejects an unknown dependency" "X depends on Z, which does not exist" \
  "$(feature add <<< "{\"epics\":[{\"id\":\"E1\",\"stories\":[$(story X '["Z"]' not_started)]}]}")"
expect "add rejects a new epic without a title" "New epic E9 needs a title and a sprint" \
  "$(feature add <<< "{\"epics\":[{\"id\":\"E9\",\"sprint\":1,\"stories\":[$(story X '[]' not_started)]}]}")"
expect "add rejects a new epic without a sprint" "New epic E9 needs a title and a sprint" \
  "$(feature add <<< "{\"epics\":[{\"id\":\"E9\",\"title\":\"Nine\",\"stories\":[$(story X '[]' not_started)]}]}")"
expect "add rejects a dependency on a later sprint" "X (sprint 1) depends on D, which is in later sprint 2" \
  "$(feature add <<< "{\"epics\":[{\"id\":\"E1\",\"stories\":[$(story X '["D"]' not_started)]}]}")"
expect "add rejects a dependency cycle" "Dependency cycle among: X, Y" \
  "$(feature add <<< "{\"epics\":[{\"id\":\"E1\",\"stories\":[$(story X '["Y"]' not_started),$(story Y '["X"]' not_started)]}]}")"
expect_unchanged "a rejected add" "$before"

expect "add accepts a new epic" "Added 1 story(ies) as not_started: E" \
  "$(feature add <<< "{\"epics\":[{\"id\":\"E2\",\"title\":\"Epic two\",\"sprint\":1,\"stories\":[$(story E '["B"]' passing)]}]}")"
expect "add ignores a submitted state" '"state": "not_started"' "$(feature show E)"
expect "waves follow dependencies" $'B C\nE\nD' "$(feature waves)"

expect "start needs passing dependencies" "E depends on B, which is not passing yet" "$(feature start E)"
expect "start activates a ready story" "B is now active" "$(feature start B)"
expect "start allows one active story" "One story at a time: B is active" "$(feature start C)"
expect "block parks the active story" "B is now blocked" "$(feature block B "waiting on an API key")"
waves_with_blocked=$(feature waves)
expect "waves skip stories behind a blocked one" "E waits on B, which is blocked, parked, or waiting on one" "$waves_with_blocked"
expect "waves keep the stories a blocked one does not hold up" $'C\nD' "$waves_with_blocked"
expect "add still works while a story is blocked" "Added 1 story(ies) as not_started: F" \
  "$(feature add <<< "{\"epics\":[{\"id\":\"E1\",\"stories\":[$(story F '[]' not_started)]}]}")"
expect "add accepts a fragment with only sprints" "Added 0 story(ies) as not_started, and 1 sprint(s)" \
  "$(feature add <<< '{"sprints":[{"sprint":3,"goal":"third"}]}')"
expect "status counts per sprint" "sprint 1 (first): 1/5 passing" "$(feature status)"
expect "status lists unmet dependencies" "E [not_started] Story E (waits on B)" "$(feature status)"

cat > feature_list.json << JSON
{"project_title":"Test","priority_legend":{},"sprints":[{"sprint":1,"goal":"first"}],
 "shared":["src/Shared/Registry.cs"],
 "epics":[{"id":"E1","title":"Epic one","sprint":1,"summary":"","stories":[
   $(story P '[]' not_started '' '["src/Notes/","src/Shared/Registry.cs"]'),
   $(story Q '[]' not_started '' '["src/Notes/NotesModule.cs"]'),
   $(story R '[]' not_started '' '["src/Tags/","src/Shared/Registry.cs"]'),
   $(story S '[]' not_started '' '[]')]}]}
JSON
waves_with_owns=$(feature waves)
expect "waves keep stories that own the same path apart" $'P R\nQ\nS' "$waves_with_owns"
expect "waves name the shared path" "Q waits for P: both own src/Notes/NotesModule.cs" "$waves_with_owns"
expect "waves run a story without owns alone" "S runs alone: it has no owns" "$waves_with_owns"
expect "add rejects owns with wildcards" "X owns must be repo-relative paths without wildcards" \
  "$(feature add <<< "{\"epics\":[{\"id\":\"E1\",\"stories\":[$(story X '[]' not_started '' '["src/*/X.cs"]')]}]}")"
expect "add rejects owns outside the repo" "X owns must be repo-relative paths" \
  "$(feature add <<< "{\"epics\":[{\"id\":\"E1\",\"stories\":[$(story X '[]' not_started '' '["../X.cs"]')]}]}")"
expect "add accepts shared paths" "Added 0 story(ies) as not_started, and 0 sprint(s)" \
  "$(feature add <<< '{"shared":["src/Shared/Schema.sql"]}')"
expect "add appends to shared" '"src/Shared/Schema.sql"' "$(cat feature_list.json)"
expect "add keeps the prd reference" '"prd": "docs/prd/e.md#FR-1"' \
  "$(feature add <<< '{"epics":[{"id":"E1","stories":[{"id":"G","name":"g","title":"g","acceptance_criteria":["x"],"test_filter":"g","prd":"docs/prd/e.md#FR-1","owns":["src/G/"]}]}]}' > /dev/null; feature show G)"

git add -A > /dev/null && git -c user.email=t@t -c user.name=t commit -qm base && git branch -M main && git switch -qc feat/p
feature start P > /dev/null
mkdir -p src/Notes src/Tags src/Shared && touch src/Notes/Note.cs src/Shared/Registry.cs && echo "- P added notes" > PROGRESS.md
expect "scope accepts owned, shared and harness files" "P changed only files it owns" "$(feature scope P)"
touch src/Tags/Tag.cs
expect "scope names a file outside owns" "src/Tags/Tag.cs" "$(feature scope P)"
expect "done refuses changes outside owns" "P changed files outside its owns" "$(feature done P)"

if (( failures > 0 )); then
  echo "$failures feature.sh test(s) failed."
  exit 1
fi
echo "feature.sh tests passed."
