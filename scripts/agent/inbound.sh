#!/usr/bin/env bash
set -euo pipefail

readonly USAGE='Usage: scripts/agent/inbound.sh [--watch]

Turns edits and card moves made on GitHub into one sync pull request that merges itself when CI is green.
Run it on a clean, up to date default branch. --watch repeats every 30 seconds.'
readonly SYNC=scripts/agent/github-sync.sh
readonly BRANCH_PREFIX=sync/backlog
readonly WATCH_SECONDS=30

main() {
  cd "$(git rev-parse --show-toplevel)"
  case "${1:-} $#" in
    " 0") sync_once ;;
    "--watch 1") while true; do sync_once || true; sleep "$WATCH_SECONDS"; done ;;
    *) fail "$USAGE" ;;
  esac
}

sync_once() {
  local default_branch branch url
  default_branch=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
  [[ "$(git branch --show-current)" == "$default_branch" ]] || fail "Check out $default_branch first."
  [[ -z "$(git status --porcelain)" ]] || fail "The working tree is not clean."
  git pull -q --ff-only
  if [[ -n "$(open_sync_pull_requests)" ]]; then
    echo "inbound: a sync pull request is already open."
    return 0
  fi
  bash "$SYNC" pull
  bash "$SYNC" pull-board
  [[ -n "$(git status --porcelain feature_list.json)" ]] || return 0
  branch="$BRANCH_PREFIX-$(date -u +%Y%m%d%H%M%S)"
  git switch -q -c "$branch"
  git add feature_list.json
  git -c core.hooksPath=/dev/null commit -qm "chore: sync backlog from GitHub"
  git push -q -u origin "$branch"
  url=$(gh pr create --base "$default_branch" --title "chore: sync backlog from GitHub" \
    --body "Edits and card moves made on GitHub, applied to feature_list.json by scripts/agent/inbound.sh. CI runs on this pull request and it merges itself when green.")
  gh pr merge "$url" --auto --squash > /dev/null
  git switch -q "$default_branch"
  echo "inbound: opened $url"
}

open_sync_pull_requests() {
  gh pr list --state open --json headRefName --jq ".[] | select(.headRefName | startswith(\"$BRANCH_PREFIX\")) | .headRefName"
}

fail() {
  echo "$1" >&2
  exit 1
}

main "$@"
