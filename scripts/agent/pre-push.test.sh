#!/usr/bin/env bash
set -uo pipefail

readonly HOOK="$(cd "$(dirname "$0")/../.." && pwd)/.husky/pre-push"
readonly ZERO=0000000000000000000000000000000000000000
readonly UNKNOWN=1234567890abcdef1234567890abcdef12345678
failures=0

expect() {
  local description=$1 expected=$2 actual=$3
  [[ "$actual" == "$expected" ]] && return
  echo "FAIL: $description"
  echo "  expected: $expected"
  echo "  got:      $actual"
  failures=$((failures + 1))
}

hook_verdict() {
  printf '%s\n' "$1" | sh .husky/pre-push origin url > /dev/null 2>&1 && echo allowed || echo refused
}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
cd "$sandbox" && git init -q -b main && mkdir -p .husky/_
cp "$HOOK" .husky/pre-push && : > .husky/_/husky.sh
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
base=$(git rev-parse HEAD)
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m child
child=$(git rev-parse HEAD)
git switch -q --detach "$base"
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m sibling
sibling=$(git rev-parse HEAD)

expect "a push to main is refused" refused "$(hook_verdict "refs/heads/feat/x $child refs/heads/main $base")"
expect "deleting main is refused" refused "$(hook_verdict "(delete) $ZERO refs/heads/main $base")"
expect "a new feature branch is allowed" allowed "$(hook_verdict "refs/heads/feat/x $child refs/heads/feat/x $ZERO")"
expect "a fast-forward of a feature branch is allowed" allowed "$(hook_verdict "refs/heads/feat/x $child refs/heads/feat/x $base")"
expect "a force push that drops pushed commits is refused" refused "$(hook_verdict "refs/heads/feat/x $sibling refs/heads/feat/x $child")"
expect "deleting a feature branch is allowed" allowed "$(hook_verdict "(delete) $ZERO refs/heads/feat/x $child")"
expect "a remote commit this clone never fetched is refused" refused "$(hook_verdict "refs/heads/feat/x $child refs/heads/feat/x $UNKNOWN")"
expect "a new tag is allowed" allowed "$(hook_verdict "refs/tags/v1 $child refs/tags/v1 $ZERO")"
expect "moving a pushed tag back is refused" refused "$(hook_verdict "refs/tags/v1 $sibling refs/tags/v1 $child")"
expect "one refused ref refuses the whole push" refused "$(hook_verdict "refs/heads/feat/x $child refs/heads/feat/x $ZERO
refs/heads/feat/x $child refs/heads/main $base")"

git init -q --bare remote.git && git remote add origin remote.git
git switch -q -c feat/x "$child"
git -c core.hooksPath=.husky push -q --dry-run origin HEAD:main > /dev/null 2>&1 && verdict=allowed || verdict=refused
expect "git runs the hook for a real push to main" refused "$verdict"

if (( failures > 0 )); then
  echo "$failures pre-push test(s) failed."
  exit 1
fi
echo "pre-push tests passed."