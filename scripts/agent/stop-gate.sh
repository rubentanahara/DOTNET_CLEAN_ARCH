#!/usr/bin/env bash
set -uo pipefail

readonly MAX_ATTEMPTS=3
readonly FAILURE_LINES=40
readonly LOGS=.agent
readonly ATTEMPTS_FILE=$LOGS/stop-gate-attempts
readonly PASSED_FILE=$LOGS/stop-gate-passed
readonly GAVE_UP_FILE=$LOGS/stop-gate-gave-up

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

working_tree_fingerprint() {
  {
    git rev-parse HEAD 2> /dev/null
    git diff HEAD --binary 2> /dev/null
    git ls-files --others --exclude-standard | git hash-object --stdin-paths
  } | git hash-object --stdin
}

recorded() {
  [[ -f "$1" && "$(cat "$1")" == "$2" ]]
}

failure_excerpt() {
  grep -v '^make: \*\*\*' "$LOGS/check.log" | tail -n "$FAILURE_LINES" | tr -d '\000-\010\013\014\016-\037'
}

cd "$(git rev-parse --show-toplevel)" || exit 0
mkdir -p "$LOGS"

if [[ -z "$(git status --porcelain)" ]]; then
  rm -f "$ATTEMPTS_FILE"
  exit 0
fi

fingerprint=$(working_tree_fingerprint)
recorded "$PASSED_FILE" "$fingerprint" && exit 0
recorded "$GAVE_UP_FILE" "$fingerprint" && exit 0

if make check > "$LOGS/check.log" 2>&1; then
  echo "$fingerprint" > "$PASSED_FILE"
  rm -f "$ATTEMPTS_FILE"
  exit 0
fi

attempts=$(( $(cat "$ATTEMPTS_FILE" 2> /dev/null || echo 0) + 1 ))
echo "$attempts" > "$ATTEMPTS_FILE"

if (( attempts > MAX_ATTEMPTS )); then
  rm -f "$ATTEMPTS_FILE"
  echo "$fingerprint" > "$GAVE_UP_FILE"
  block_stop "make check still fails after $MAX_ATTEMPTS attempts. Stop changing code. Tell the user plainly that the work is not done, quote the failure below, and list what you tried."$'\n\n'"$(failure_excerpt)"
fi

block_stop "Not done: make check failed (attempt $attempts of $MAX_ATTEMPTS). Fix the cause, run make check until it prints CHECK PASSED, then finish. Full output: $LOGS/check.log."$'\n\n'"$(failure_excerpt)"
