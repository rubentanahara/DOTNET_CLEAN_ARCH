#!/usr/bin/env bash
set -euo pipefail

readonly FEATURES_FILE=feature_list.json
readonly USAGE='Usage:
  scripts/agent/feature.sh add <id> "<behavior>" "<dotnet test filter>"
  scripts/agent/feature.sh start <id>
  scripts/agent/feature.sh done <id>
  scripts/agent/feature.sh block <id> "<reason>"'

fail() {
  echo "$1" >&2
  exit 1
}

state_of() {
  jq -r --arg id "$1" '.[] | select(.id == $id) | .state' "$FEATURES_FILE"
}

require_state() {
  local id=$1 allowed=$2 state
  state=$(state_of "$id")
  [[ -n "$state" ]] || fail "No feature $id in $FEATURES_FILE."
  [[ " $allowed " == *" $state "* ]] || fail "$id is $state. This action needs: $allowed."
}

write_features() {
  local filter=$1
  shift
  jq "$@" "$filter" "$FEATURES_FILE" > "$FEATURES_FILE.tmp"
  mv "$FEATURES_FILE.tmp" "$FEATURES_FILE"
}

set_state() {
  write_features 'map(if .id == $id then .state = $state | .evidence = $evidence else . end)' \
    --arg id "$1" --arg state "$2" --arg evidence "$3"
  echo "$1 is now $2."
}

add_feature() {
  local id=$1 behavior=$2 test_filter=$3
  [[ -z "$(state_of "$id")" ]] || fail "$id already exists in $FEATURES_FILE."
  write_features '. + [{id: $id, behavior: $behavior, test_filter: $test_filter, state: "not_started", evidence: ""}]' \
    --arg id "$id" --arg behavior "$behavior" --arg test_filter "$test_filter"
  echo "$id added as not_started."
}

start_feature() {
  local id=$1 active
  require_state "$id" "not_started blocked"
  active=$(jq -r '[.[] | select(.state == "active") | .id] | join(", ")' "$FEATURES_FILE")
  [[ -z "$active" ]] || fail "One feature at a time: $active is active. Finish it with done or park it with block first."
  set_state "$id" active ""
}

count_passed_tests() {
  { grep -oE 'Passed: +[0-9]+' || true; } | awk '{ total += $2 } END { print total + 0 }'
}

finish_feature() {
  local id=$1 test_filter output passed revision
  require_state "$id" "active"
  make check || fail "make check failed, so $id stays active. Fix the failures above, then run done again."
  test_filter=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .test_filter' "$FEATURES_FILE")
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

block_feature() {
  require_state "$1" "not_started active"
  set_state "$1" blocked "$2"
}

cd "$(git rev-parse --show-toplevel)"
command -v jq > /dev/null || fail "jq is required. Install it (brew install jq, or winget install jqlang.jq) and retry."

case "${1:-} $#" in
  "add 4") add_feature "$2" "$3" "$4" ;;
  "start 2") start_feature "$2" ;;
  "done 2") finish_feature "$2" ;;
  "block 3") block_feature "$2" "$3" ;;
  *) fail "$USAGE" ;;
esac
