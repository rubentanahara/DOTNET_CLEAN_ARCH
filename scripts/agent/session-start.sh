#!/usr/bin/env bash
set -uo pipefail

readonly PROGRESS_FILE=PROGRESS.md
readonly FEATURES_FILE=feature_list.json
readonly PROGRESS_MAX_LINES=60
readonly LOG_FILE=.agent/session-start.log

cd "$(git rev-parse --show-toplevel)" || exit 0

open_features() {
  jq -r '.[] | select(.state != "passing") | "\(.id) [\(.state)] \(.behavior)"' "$FEATURES_FILE" 2> /dev/null
}

progress_excerpt() {
  head -n "$PROGRESS_MAX_LINES" "$PROGRESS_FILE" 2> /dev/null
}

calling_cli() {
  local pid=$PPID name
  while [ "${pid:-1}" -gt 1 ]; do
    name=$(basename "$(ps -o comm= -p "$pid")")
    case "$name" in claude | copilot | codex)
      echo "$name"
      return
      ;;
    esac
    pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
  done
  echo unknown
}

cli=$(calling_cli)
check_output=$(make check 2>&1)
check_result=$(echo "$check_output" | tail -n 1)

context=$(
  echo "Session start. Read this before editing. The make check baseline below ran just now."
  echo
  echo "## $PROGRESS_FILE"
  progress_excerpt
  echo
  echo "## Open features in $FEATURES_FILE (anything not passing)"
  open_features | grep . || echo "None. Every feature is passing."
  echo
  echo "## make check"
  echo "$check_output"
)

open_count=$(open_features | grep -c .)
notice="session-start hook ran in $cli: loaded PROGRESS.md and $open_count open feature(s). make check: $check_result"
mkdir -p "$(dirname "$LOG_FILE")"
echo "$(date '+%Y-%m-%d %H:%M:%S') $notice" >> "$LOG_FILE"

jq -n --arg context "$context" --arg notice "$notice" --arg cli "$cli" '{
  systemMessage: $notice,
  hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}
} + if $cli == "codex" then {} else {additionalContext: $context} end'
