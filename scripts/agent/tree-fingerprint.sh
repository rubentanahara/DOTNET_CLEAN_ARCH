#!/usr/bin/env bash
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

{
  git rev-parse HEAD 2> /dev/null
  git diff HEAD --binary 2> /dev/null
  git ls-files --others --exclude-standard | git hash-object --stdin-paths
} | git hash-object --stdin
