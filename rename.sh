#!/usr/bin/env bash
set -euo pipefail

readonly OLD_NAME="CleanTemplate"
readonly OLD_CONTAINER_PREFIX="clean-architecture"
readonly OLD_JWT_NAME="ReminderService"
readonly EXCLUDE_SCRIPTS=(":!rename.sh" ":!rename.ps1")
readonly NEW_NAME="${1:-}"

if [[ ! "$NEW_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$ ]]; then
  echo "Usage: ./rename.sh <NewName>    e.g. ./rename.sh Acme.Billing" >&2
  echo "Renames the solution, then replaces the git history with a fresh 'git init'." >&2
  exit 1
fi

cd "$(dirname "$0")"

if ! git grep -q "$OLD_NAME" -- . "${EXCLUDE_SCRIPTS[@]}"; then
  echo "No '$OLD_NAME' left to rename." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain -- . "${EXCLUDE_SCRIPTS[@]}")$(git log --branches --not --remotes --oneline)$(git stash list)" ]]; then
  echo "Commit and push all changes, and drop any stashes, first: the git history gets replaced." >&2
  exit 1
fi

readonly NEW_CONTAINER_PREFIX="$(tr '[:upper:]' '[:lower:]' <<< "$NEW_NAME")"

rm -rf artifacts

git grep -lz -e "$OLD_NAME" -e "$OLD_CONTAINER_PREFIX" -e "$OLD_JWT_NAME" -- . "${EXCLUDE_SCRIPTS[@]}" |
  xargs -0 perl -pi -e "s/$OLD_NAME/$NEW_NAME/g; s/$OLD_CONTAINER_PREFIX/$NEW_CONTAINER_PREFIX/g; s/$OLD_JWT_NAME/$NEW_NAME/g"

find . -depth -name "*$OLD_NAME*" -not -path './.git/*' | while IFS= read -r path; do
  mv "$path" "$(dirname "$path")/$(basename "$path" | sed "s/$OLD_NAME/$NEW_NAME/g")"
done

dotnet format "$NEW_NAME.slnx" --diagnostics SA1210

rm -f rename.sh rename.ps1
rm -rf .git
git init -q -b main

echo "Renamed $OLD_NAME to $NEW_NAME and started a fresh git repository."
echo "Next: git add -A && git commit -m 'chore: initial commit' && git remote add origin <your-repo-url>"
