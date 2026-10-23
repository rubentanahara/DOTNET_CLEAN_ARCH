#!/usr/bin/env bash
set -uo pipefail

readonly PROGRESS_FILE=PROGRESS.md
readonly FEATURES_FILE=feature_list.json
readonly FEATURE_SCRIPT=scripts/agent/feature.sh
readonly HOOK_CONTEXT_MAX_CHARS=9000
readonly WAVES_SHOWN=5
readonly LOG_FILE=.agent/session-start.log
readonly FINGERPRINT_SCRIPT=scripts/agent/tree-fingerprint.sh

readonly HOOK_INPUT_TIMEOUT_SECONDS=2
hook_input=""
[[ -t 0 ]] || IFS= read -r -d '' -t "$HOOK_INPUT_TIMEOUT_SECONDS" hook_input || true
session_id=$(grep -oE '"session_?[iI]d" *: *"[^"]+"' <<< "$hook_input" | head -n 1 | sed -E 's/.*"([^"]+)"$/\1/' | tr -cd 'A-Za-z0-9_-')
readonly BASELINE_FILE=.agent/session-baseline${session_id:+-$session_id}
readonly BASELINE_RETENTION_DAYS=7

cd "$(git rev-parse --show-toplevel)" || exit 0

open_story_count() {
  jq '[.epics[].stories[] | select(.state != "passing")] | length' "$FEATURES_FILE" 2> /dev/null || echo 0
}

backlog_summary() {
  bash "$FEATURE_SCRIPT" status 2>&1
  echo
  echo "Ready now, wave by wave (stories on one line can run in parallel):"
  local waves
  waves=$(bash "$FEATURE_SCRIPT" waves 2>&1) || { echo "$waves"; return; }
  echo "${waves:-Nothing. Every scheduled story is passing.}" | head -n "$WAVES_SHOWN"
}

fit_hook_limit() {
  local text=$1
  local note="[Cut to $HOOK_CONTEXT_MAX_CHARS characters to stay under the 10000 Claude Code keeps in context. Read $PROGRESS_FILE for the rest.]"
  if (( ${#text} <= HOOK_CONTEXT_MAX_CHARS )); then
    printf '%s' "$text"
    return
  fi
  text=${text:0:HOOK_CONTEXT_MAX_CHARS - ${#note} - 1}
  printf '%s\n%s' "${text%$'\n'*}" "$note"
}

record_session_baseline() {
  find .agent -name 'session-baseline-*' -mtime +"$BASELINE_RETENTION_DAYS" -delete 2> /dev/null
  {
    bash "$FINGERPRINT_SCRIPT"
    git hash-object "$PROGRESS_FILE" 2> /dev/null
  } > "$BASELINE_FILE"
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
  echo "Session start. Read this before editing. make check ran just now: $check_result"
  echo
  echo "## make check"
  echo "$check_output"
  echo
  echo "## Backlog in $FEATURES_FILE (scripts/agent/feature.sh show <id> prints one story)"
  backlog_summary
  echo
  echo "## $PROGRESS_FILE"
  cat "$PROGRESS_FILE" 2> /dev/null
)
context=$(fit_hook_limit "$context")

notice="session-start hook ran in $cli: loaded PROGRESS.md and $(open_story_count) open story(ies). make check: $check_result"
mkdir -p "$(dirname "$LOG_FILE")"
record_session_baseline
echo "$(date '+%Y-%m-%d %H:%M:%S') $notice" >> "$LOG_FILE"

jq -n --arg context "$context" --arg notice "$notice" --arg cli "$cli" '{
  systemMessage: $notice,
  hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}
} + if $cli == "codex" then {} else {additionalContext: $context} end'
