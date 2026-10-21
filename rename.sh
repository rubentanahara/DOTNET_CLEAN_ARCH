#!/usr/bin/env bash
set -euo pipefail

readonly OLD_NAME="CleanTemplate"
readonly OLD_CONTAINER_PREFIX="clean-architecture"
readonly SCRIPT_NAME="$(basename "$0")"
readonly NEW_NAME="${1:-}"

if [[ ! "$NEW_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$ ]]; then
  echo "Usage: ./$SCRIPT_NAME <NewName>    e.g. ./$SCRIPT_NAME Acme.Billing" >&2
  exit 1
fi

cd "$(dirname "$0")"

if ! git grep -q "$OLD_NAME" -- . ":!$SCRIPT_NAME"; then
  echo "No '$OLD_NAME' left to rename." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain -- . ":!$SCRIPT_NAME")" ]]; then
  echo "Commit or stash your changes first, so the rename can be undone with git." >&2
  exit 1
fi

readonly NEW_CONTAINER_PREFIX="$(tr '[:upper:]' '[:lower:]' <<< "$NEW_NAME")"

rm -rf artifacts

git grep -lz -e "$OLD_NAME" -e "$OLD_CONTAINER_PREFIX" -- . ":!$SCRIPT_NAME" |
  xargs -0 perl -pi -e "s/$OLD_NAME/$NEW_NAME/g; s/$OLD_CONTAINER_PREFIX/$NEW_CONTAINER_PREFIX/g"

find . -depth -name "*$OLD_NAME*" -not -path './.git/*' | while IFS= read -r path; do
  mv "$path" "$(dirname "$path")/$(basename "$path" | sed "s/$OLD_NAME/$NEW_NAME/g")"
done

dotnet format "$NEW_NAME.slnx" --diagnostics SA1210

rm -- "$SCRIPT_NAME"

echo "Renamed $OLD_NAME to $NEW_NAME. Review with 'git status', undo with 'git checkout . && git clean -fd'."
