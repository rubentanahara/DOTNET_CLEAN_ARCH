#!/usr/bin/env bash
set -uo pipefail

readonly SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
export HARNESS_GITHUB_SYNC=off
failures=0

expect() {
  local description=$1 expected=$2 actual=$3
  [[ "$actual" == "$expected" ]] && return
  echo "FAIL: $description"
  echo "  expected: $expected"
  echo "  got:      $actual"
  failures=$((failures + 1))
}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
cd "$sandbox" && git init -q && mkdir -p scripts/agent
cp "$SCRIPTS_DIR/feature.sh" scripts/agent/
cat > feature_list.json << 'JSON'
{"project_title":"Test","priority_legend":{},"sprints":[{"sprint":1,"goal":"first"}],
 "epics":[{"id":"E1","title":"Epic","sprint":1,"summary":"","stories":[
   {"id":"F05","name":"Create Tag (v2)!","title":"As a user, I want tags","acceptance_criteria":["Given, When, Then"],
    "test_filter":"FullyQualifiedName~TagTests","depends_on":[],"owns":["src/Tags/"],"state":"not_started","evidence":""}]}]}
JSON

source "$SCRIPTS_DIR/run.sh"
ROOT=$sandbox

expect "branch names are lowercase slugs" "feat/f05-create-tag-v2" "$(branch_name F05)"
expect "session names keep the story name" "F05 · Create Tag (v2)!" "$(session_name F05)"
expect "slugs stop at the length limit without a trailing dash" "feat/$(printf 'a%.0s' $(seq 40))" "feat/$(slug "$(printf 'a%.0s' $(seq 45))")"
expect "claude defaults to sonnet 5.5" "claude-sonnet-5-5" "$(default_model claude)"
expect "copilot defaults to auto" "auto" "$(default_model copilot)"
expect "codex defaults to gpt-5.6-terra" "gpt-5.6-terra" "$(default_model codex)"
expect "commit subjects start lowercase" "create Tag (v2)!" "$(lowercase_first "Create Tag (v2)!")"

printf 'table\n\n**VERIFY: PASS**\n' > pass.md
printf 'VERIFY: FAIL 1 of 3 criteria, 0 other findings\nmore text\n' > fail.md
printf 'no verdict here\n' > none.md
printf 'VERIFY: PASS\nlater it changed its mind\nVERIFY: FAIL 2 of 3 criteria, 1 other findings\n' > both.md
expect "a bold PASS line counts" "VERIFY: PASS" "$(verdict_of pass.md)"
expect "a FAIL line keeps its counts" "VERIFY: FAIL 1 of 3 criteria, 0 other findings" "$(verdict_of fail.md)"
expect "no VERIFY line gives no verdict" "" "$(verdict_of none.md)"
expect "the last VERIFY line wins" "VERIFY: FAIL 2 of 3 criteria, 1 other findings" "$(verdict_of both.md)"

record F05 shipped "https://example/pull/1" 2> /dev/null
expect "result_of reads a matching result" "https://example/pull/1" "$(result_of F05 shipped)"
expect "result_of refuses another outcome" "" "$(result_of F05 blocked)"
expect "a story without a worktree has no worktree state" "" "$(worktree_state F05)"

tdd_repo=$(mktemp -d)
git -C "$tdd_repo" init -q -b main
git -C "$tdd_repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$tdd_repo" switch -q -c feat/x
BASE_BRANCH=main
no_commit_message=$(tdd_commit_order F05 "$tdd_repo")
expect "the gate names the missing commit" "TDD rule: there is no commit." "${no_commit_message%% Make*}"
mkdir -p "$tdd_repo/tests" "$tdd_repo/src"
touch "$tdd_repo/tests/XTests.cs"
git -C "$tdd_repo" add -A && git -C "$tdd_repo" -c user.email=t@t -c user.name=t commit -q -m "test(F01): proves x"
touch "$tdd_repo/src/X.cs"
git -C "$tdd_repo" add -A && git -C "$tdd_repo" -c user.email=t@t -c user.name=t commit -q -m "feat(F01): x"
tdd_first=$(git -C "$tdd_repo" log --reverse --format=%H main..HEAD | sed -n 1p)
first_commit_is_tests_only "$tdd_repo" "$tdd_first" && result=ok || result=refused
expect "a first commit with only tests is accepted" "ok" "$result"
first_commit_is_tests_only "$tdd_repo" "$(git -C "$tdd_repo" rev-parse HEAD)" && result=ok || result=refused
expect "a commit with code is refused as the first" "refused" "$result"
rm -rf "$tdd_repo"

if (( failures > 0 )); then
  echo "$failures run.sh test(s) failed."
  exit 1
fi
echo "run.sh tests passed."
