#!/usr/bin/env bash
set -uo pipefail

readonly SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly CLAUDE_HOOK_CONTEXT_LIMIT=10000
readonly LONG_PROGRESS_LINES=60
readonly LONG_PROGRESS_LINE_CHARS=400
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

contains() {
  [[ "$1" == *"$2"* ]] && echo yes || echo no
}

session_context() {
  bash scripts/agent/session-start.sh < /dev/null | jq -r '.hookSpecificOutput.additionalContext'
}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
cd "$sandbox" && git init -q && mkdir -p scripts/agent
cp "$SCRIPTS_DIR/session-start.sh" "$SCRIPTS_DIR/feature.sh" "$SCRIPTS_DIR/tree-fingerprint.sh" scripts/agent/
printf 'check:\n\t@echo "CHECK PASSED: stub"\n' > Makefile
cat > feature_list.json << 'JSON'
{"project_title":"Test","priority_legend":{},"sprints":[{"sprint":1,"goal":"first"}],
 "epics":[{"id":"E1","title":"Epic","sprint":1,"summary":"","stories":[
  {"id":"F05","name":"Create tag","title":"As user, I want tags","acceptance_criteria":["Given, When, Then"],
   "test_filter":"FullyQualifiedName~TagTests","depends_on":[],"owns":["src/Tags/"],"state":"not_started","evidence":""}]}]}
JSON

printf '# Progress\n- short state\n- LAST PROGRESS LINE\n' > PROGRESS.md
context=$(session_context)
expect "a short PROGRESS.md is kept whole" yes "$(contains "$context" "LAST PROGRESS LINE")"
expect "a short context is not cut" no "$(contains "$context" "[Cut to")"

long_line=$(printf "%0${LONG_PROGRESS_LINE_CHARS}d" 0)
{
  echo "# Progress"
  for line in $(seq "$LONG_PROGRESS_LINES"); do echo "- $line $long_line"; done
} > PROGRESS.md
context=$(session_context)
expect "a long context fits what Claude Code keeps in context" yes "$( ((${#context} <= CLAUDE_HOOK_CONTEXT_LIMIT)) && echo yes || echo no)"
expect "the make check result survives a long PROGRESS.md" yes "$(contains "$context" "CHECK PASSED: stub")"
expect "the ready stories survive a long PROGRESS.md" yes "$(contains "$context" "F05")"
expect "a cut context says where the rest is" yes "$(contains "$context" "Read PROGRESS.md for the rest.]")"

((failures == 0)) && echo "session-start tests passed" || exit 1