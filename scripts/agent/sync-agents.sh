#!/usr/bin/env bash
set -euo pipefail

readonly SOURCE_DIR="${1:-.claude/agents}"
readonly TARGET_DIR="${2:-.codex/agents}"
readonly TOML_LITERAL_DELIMITER="'''"

frontmatter_value() {
  awk -v key="$2: " 'NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside && index($0, key) == 1 { print substr($0, length(key) + 1); exit }' "$1"
}

body() {
  awk 'separators >= 2 { print; next } $0 == "---" { separators++ }' "$1"
}

write_codex_agent() {
  local agent=$1 name description instructions
  name=$(frontmatter_value "$agent" name | tr - _)
  description=$(frontmatter_value "$agent" description)
  instructions=$(body "$agent")
  [[ $name =~ ^[a-z0-9_]+$ && -n $description ]] || {
    echo "$agent needs a name of lowercase letters, digits and hyphens, and a description." >&2
    exit 1
  }
  [[ $instructions != *"$TOML_LITERAL_DELIMITER"* ]] || {
    echo "$agent contains $TOML_LITERAL_DELIMITER, which the Codex TOML copy cannot hold." >&2
    exit 1
  }
  printf 'name = "%s"\ndescription = %s\ndeveloper_instructions = %s\n%s\n%s\n' \
    "$name" "$(jq -n --arg text "$description" '$text')" \
    "$TOML_LITERAL_DELIMITER" "$instructions" "$TOML_LITERAL_DELIMITER" > "$TARGET_DIR/$name.toml"
}

rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"
for agent in "$SOURCE_DIR"/*.md; do
  write_codex_agent "$agent"
done
