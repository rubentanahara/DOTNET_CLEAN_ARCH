#!/usr/bin/env bash
set -uo pipefail

readonly MAX_ATTEMPTS=3
readonly HOOK_INPUT_TIMEOUT_SECONDS=2
readonly FAILURE_LINES=40
readonly LOGS=.agent
readonly PASSED_FILE=$LOGS/stop-gate-passed
readonly GAVE_UP_FILE=$LOGS/stop-gate-gave-up
readonly PROGRESS_FILE=PROGRESS.md
readonly FINGERPRINT_SCRIPT=scripts/agent/tree-fingerprint.sh

json_string() {
  local text=$1
  text=${text//\\/\\\\}
  text=${text//\"/\\\"}
  text=${text//$'\t'/\\t}
  text=${text//$'\r'/}
  text=${text//$'\n'/\\n}
  printf '"%s"' "$text"
}

block_stop() {
  printf '{"decision":"block","reason":%s}\n' "$(json_string "$1")"
  exit 0
}

session_id_from_hook_input() {
  grep -oE '"session_?[iI]d" *: *"[^"]+"' | head -n 1 | sed -E 's/.*"([^"]+)"$/\1/' | tr -cd 'A-Za-z0-9_-'
}

next_attempt() {
  local counter_file=$1 attempts
  attempts=$(( $(cat "$counter_file" 2> /dev/null || echo 0) + 1 ))
  echo "$attempts" > "$counter_file"
  echo "$attempts"
}

session_changes_missing_from_progress() {
  local fingerprint=$1 baseline_fingerprint="" baseline_progress
  baseline_progress=$(git rev-parse -q --verify "HEAD:$PROGRESS_FILE")
  if [[ -f "$BASELINE_FILE" ]]; then
    { read -r baseline_fingerprint; read -r baseline_progress; } < "$BASELINE_FILE"
  elif [[ -n "$session_id" ]]; then
    return 1
  fi
  [[ "$fingerprint" != "$baseline_fingerprint" && "$(git hash-object "$PROGRESS_FILE" 2> /dev/null)" == "$baseline_progress" ]]
}

recorded() {
  [[ -f "$1" && "$(cat "$1")" == "$2" ]]
}

failure_excerpt() {
  grep -v '^make: \*\*\*' "$LOGS/check.log" | tail -n "$FAILURE_LINES" | tr -d '\000-\010\013\014\016-\037'
}

hook_input=""
[[ -t 0 ]] || IFS= read -r -d '' -t "$HOOK_INPUT_TIMEOUT_SECONDS" hook_input || true
session_id=$(session_id_from_hook_input <<< "$hook_input")
readonly BASELINE_FILE=$LOGS/session-baseline${session_id:+-$session_id}
readonly ATTEMPTS_FILE=$LOGS/stop-gate-attempts${session_id:+-$session_id}
readonly PROGRESS_GAVE_UP_FILE=$LOGS/progress-gate-gave-up${session_id:+-$session_id}
readonly PROGRESS_ATTEMPTS_FILE=$LOGS/progress-gate-attempts${session_id:+-$session_id}

cd "$(git rev-parse --show-toplevel)" || exit 0
mkdir -p "$LOGS"

if [[ -z "$(git status --porcelain)" ]]; then
  rm -f "$ATTEMPTS_FILE"
  exit 0
fi

fingerprint=$(bash "$FINGERPRINT_SCRIPT")
if ! recorded "$PROGRESS_GAVE_UP_FILE" "$fingerprint" && session_changes_missing_from_progress "$fingerprint"; then
  attempts=$(next_attempt "$PROGRESS_ATTEMPTS_FILE")
  if (( attempts > MAX_ATTEMPTS )); then
    rm -f "$PROGRESS_ATTEMPTS_FILE"
    echo "$fingerprint" > "$PROGRESS_GAVE_UP_FILE"
    block_stop "$PROGRESS_FILE is still unchanged after $MAX_ATTEMPTS attempts. If this session changed files, add what changed, why, and what comes next to $PROGRESS_FILE. If it changed nothing, another session did: say so and stop."
  fi
  block_stop "Not done: files changed during this session but $PROGRESS_FILE did not (attempt $attempts of $MAX_ATTEMPTS). Add what changed, why, and what comes next to it, then finish."
fi
rm -f "$PROGRESS_ATTEMPTS_FILE"
recorded "$PASSED_FILE" "$fingerprint" && exit 0
recorded "$GAVE_UP_FILE" "$fingerprint" && exit 0

if make check > "$LOGS/check.log" 2>&1; then
  echo "$fingerprint" > "$PASSED_FILE"
  rm -f "$ATTEMPTS_FILE"
  exit 0
fi

attempts=$(next_attempt "$ATTEMPTS_FILE")

if (( attempts > MAX_ATTEMPTS )); then
  rm -f "$ATTEMPTS_FILE"
  echo "$fingerprint" > "$GAVE_UP_FILE"
  block_stop "make check still fails after $MAX_ATTEMPTS attempts. Stop changing code. Tell the user plainly that the work is not done, quote the failure below, and list what you tried."$'\n\n'"$(failure_excerpt)"
fi

block_stop "Not done: make check failed (attempt $attempts of $MAX_ATTEMPTS). Fix the cause, run make check until it prints CHECK PASSED, then finish. Full output: $LOGS/check.log."$'\n\n'"$(failure_excerpt)"
