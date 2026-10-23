#!/usr/bin/env bash
set -uo pipefail

readonly SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
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
mkdir -p "$sandbox/source"

cat > "$sandbox/source/code-reviewer.md" << 'AGENT'
---
name: code-reviewer
description: Reviews "risky" code for the team's C:\ paths.
tools: Read, Grep
---

Read `AGENTS.md` first.
---
Never say "done" without evidence.
AGENT

bash "$SCRIPTS_DIR/sync-agents.sh" "$sandbox/source" "$sandbox/target"
expect "writes one TOML file per agent, named with underscores" "code_reviewer.toml" "$(ls "$sandbox/target")"
expect "converts the agent to Codex fields, escaping the description and keeping the body verbatim" \
  "$(printf '%s\n' 'name = "code_reviewer"' \
    'description = "Reviews \"risky\" code for the team'"'"'s C:\\ paths."' \
    "developer_instructions = '''" '' 'Read `AGENTS.md` first.' '---' 'Never say "done" without evidence.' "'''")" \
  "$(cat "$sandbox/target/code_reviewer.toml")"

printf -- "---\nname: Bad Name\ndescription: x\n---\nbody\n" > "$sandbox/source/bad.md"
bash "$SCRIPTS_DIR/sync-agents.sh" "$sandbox/source" "$sandbox/target" 2> /dev/null
expect "refuses a name Codex cannot load" "1" "$?"

printf -- "---\nname: quoted\ndescription: x\n---\nsay '''\n" > "$sandbox/source/bad.md"
bash "$SCRIPTS_DIR/sync-agents.sh" "$sandbox/source" "$sandbox/target" 2> /dev/null
expect "refuses a body a TOML literal string cannot hold" "1" "$?"

if [[ $failures -gt 0 ]]; then
  exit 1
fi
echo "sync-agents.sh tests passed."
