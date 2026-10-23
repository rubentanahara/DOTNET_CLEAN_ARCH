#!/usr/bin/env bash
set -uo pipefail

readonly USAGE='Usage: scripts/agent/run.sh [--cli claude|codex|copilot] [--checker claude|codex|copilot] [--model <m>] [--checker-model <m>] [--parallel N] [--no-merge] [--story <id>] [--dry-run]

Runs the first wave of scripts/agent/feature.sh waves. Each story gets its own worktree and branch and goes through:
implement (a session named "<id> · <name>"), make check, scope and test gate, an independent read-only review
(the verify skill, in a fresh session), feature.sh done, then a commit, a push and a pull request.

  --cli       CLI that implements. Default: copilot.
  --checker   CLI that reviews. Default: the same as --cli.
  --model     model of the implementer. Default: claude-sonnet-5.5 (copilot), claude-sonnet-5-5 (claude) or gpt-5.6-terra (codex).
  --checker-model  model of the reviewer. Default: claude-opus-5.5 (copilot), otherwise the default of the checker CLI.
  --parallel  how many stories of a wave run at once, one tmux pane each. Default: 1.
  --no-merge  stop at open pull requests. Default: merge each pull request once CI is green, then run the next wave.
  --story     run only this story.
  --dry-run   print what would run, and start nothing.'
readonly MAX_ATTEMPTS=3
readonly CLAUDE_DEFAULT_MODEL=claude-sonnet-5-5
readonly COPILOT_DEFAULT_MODEL=claude-sonnet-5.5
readonly COPILOT_DEFAULT_CHECKER_MODEL=claude-opus-5.5
readonly CODEX_DEFAULT_MODEL=gpt-5.6-terra
readonly WORKTREES_DIR=.worktrees
readonly RUNS_DIR=.agent/runs
readonly RUNNER_DIR=.agent/runner
readonly FEATURE=scripts/agent/feature.sh
readonly SYNC=scripts/agent/github-sync.sh
readonly FINGERPRINT=scripts/agent/tree-fingerprint.sh
readonly POLL_SECONDS=15
readonly CHECKS_APPEAR_ROUNDS=20
readonly TEST_PATH_PREFIX=tests/
readonly FEEDBACK_LINES=60
readonly SLUG_MAX_LENGTH=40
readonly HUSKY_RUNTIME_DIR=.husky/_

main() {
  parse_arguments "$@"
  cd "$(git rev-parse --show-toplevel)" || exit 1
  ROOT=$PWD
  BASE_BRANCH=$(git branch --show-current)
  [[ -n "$BASE_BRANCH" ]] || fail "Check out a branch first, normally main: stories branch from it and their pull requests target it."
  [[ -z "$(git status --porcelain)" ]] || fail "The working tree is not clean. Commit or stash first: stories branch from HEAD."
  if $MERGE && [[ "$BASE_BRANCH" != "$(default_branch)" ]]; then
    fail "Merging needs the default branch ($(default_branch)) checked out, because it pulls each merge before the next wave. Use --no-merge to run from another branch."
  fi
  mkdir -p "$RUNS_DIR"
  if [[ -n "$ONLY_STORY" ]] && ! $DRY_RUN; then
    run_story "$ONLY_STORY"
    exit $?
  fi
  run_waves
}

parse_arguments() {
  CLI=copilot CHECKER="" MODEL="" CHECKER_MODEL="" PARALLEL=1 MERGE=true ONLY_STORY="" DRY_RUN=false
  while (( $# > 0 )); do
    case "$1" in
      --cli) CLI=${2:?$USAGE}; shift 2 ;;
      --checker) CHECKER=${2:?$USAGE}; shift 2 ;;
      --model) MODEL=${2:?$USAGE}; shift 2 ;;
      --checker-model) CHECKER_MODEL=${2:?$USAGE}; shift 2 ;;
      --parallel) PARALLEL=${2:?$USAGE}; shift 2 ;;
      --no-merge) MERGE=false; shift ;;
      --story) ONLY_STORY=${2:?$USAGE}; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      *) fail "$USAGE" ;;
    esac
  done
  CHECKER=${CHECKER:-$CLI}
  MODEL=${MODEL:-$(default_model "$CLI")}
  CHECKER_MODEL=${CHECKER_MODEL:-$(default_checker_model "$CHECKER")}
  local cli
  for cli in "$CLI" "$CHECKER"; do
    [[ " claude codex copilot " == *" $cli "* ]] || fail "Unknown CLI '$cli'. Use claude, codex or copilot."
    command -v "$cli" > /dev/null || fail "$cli is not installed."
  done
  [[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || fail "--parallel takes a positive number."
}

run_waves() {
  local ids
  while true; do
    $MERGE && { git pull -q --ff-only || fail "git pull failed on $BASE_BRANCH."; }
    ids=$(ready_stories)
    if [[ -z "$ids" ]]; then
      report "Nothing left to start in the first wave. $(waiting_summary)"
      return 0
    fi
    if $DRY_RUN; then
      print_plan "$ids"
      return 0
    fi
    run_wave "$ids"
    print_results "$ids"
    if ! $MERGE; then
      report "Stopped at open pull requests. Merge them, then run again for the next wave."
      return 0
    fi
    merge_wave "$ids" || return 1
  done
}

ready_stories() {
  local first_wave id
  if [[ -n "$ONLY_STORY" ]]; then
    first_wave=$ONLY_STORY
  else
    first_wave=$(bash "$FEATURE" waves 2> /dev/null | head -n 1)
  fi
  for id in $first_wave; do
    if [[ -n "$(open_pull_request "$id")" ]]; then
      echo "skip $id: in review at $(open_pull_request "$id")" >&2
    elif [[ "$(worktree_state "$id")" == blocked ]]; then
      echo "skip $id: blocked in $WORKTREES_DIR/$id. Unblock it with feature.sh start there, or remove the worktree." >&2
    else
      echo "$id"
    fi
  done
}

waiting_summary() {
  local open
  open=$(gh pr list --state open --base "$BASE_BRANCH" --json number,title,headRefName \
    --jq '.[] | select(.headRefName | startswith("feat/")) | "#\(.number) \(.title)"' 2> /dev/null)
  [[ -n "$open" ]] && echo "Waiting for: $(tr '\n' ';' <<< "$open")" && return
  bash "$FEATURE" status 2> /dev/null | head -n 1
}

print_plan() {
  local id
  echo "Base: $BASE_BRANCH ($(git rev-parse --short HEAD)). Implementer: $CLI ($MODEL). Reviewer: $CHECKER ($CHECKER_MODEL), fresh read-only session. Parallel: $PARALLEL. Merge: $MERGE."
  echo "Wave:"
  for id in $1; do
    echo "  $(session_name "$id")  branch $(branch_name "$id")  worktree $WORKTREES_DIR/$id  tests $(story_field "$id" test_filter)"
  done
  if $MERGE; then echo "Then: merge each pull request once CI is green, and run the next wave."; else echo "Then: stop at the open pull requests."; fi
}

run_wave() {
  local ids=($1) id
  if (( PARALLEL == 1 || ${#ids[@]} == 1 )); then
    for id in "${ids[@]}"; do run_story "$id"; done
    return
  fi
  command -v tmux > /dev/null || fail "--parallel needs tmux. Install it, or run with --parallel 1."
  local start
  for (( start = 0; start < ${#ids[@]}; start += PARALLEL )); do
    run_in_panes "${ids[@]:start:PARALLEL}"
  done
}

run_in_panes() {
  local id window pane first_pane session target
  session=$(tmux display-message -p '#S' 2> /dev/null || true)
  if [[ -z "$session" ]]; then
    session="harness-run"
    tmux has-session -t "$session" 2> /dev/null || tmux new-session -d -s "$session" -c "$ROOT"
    report "Panes are in tmux session $session. Watch them with: tmux attach -t $session"
  fi
  window=$(tmux new-window -d -t "$session" -n "wave" -c "$ROOT" -P -F '#{window_id}')
  first_pane=$(tmux list-panes -t "$window" -F '#{pane_id}')
  tmux set-option -w -t "$window" pane-border-status top > /dev/null
  tmux set-option -w -t "$window" pane-border-format ' #{pane_title} ' > /dev/null
  for id in "$@"; do
    rm -f "$(result_file "$id")"
    pane=$(tmux split-window -d -t "$window" -c "$ROOT" -P -F '#{pane_id}')
    tmux select-pane -t "$pane" -T "$(session_name "$id")"
    tmux set-option -p -t "$pane" allow-set-title off > /dev/null
    tmux select-layout -t "$window" tiled > /dev/null
    tmux send-keys -t "$pane" "bash $0 --story $id --cli $CLI --checker $CHECKER --model $MODEL --checker-model $CHECKER_MODEL; echo 'Pane done. Press Enter to close.'; read" Enter
  done
  tmux kill-pane -t "$first_pane"
  tmux select-layout -t "$window" tiled > /dev/null
  for id in "$@"; do
    until [[ -f "$(result_file "$id")" ]]; do sleep "$POLL_SECONDS"; done
  done
}

run_story() {
  local id=$1 dir="$ROOT/$WORKTREES_DIR/$1" attempt feedback="" verdict passed=false
  [[ -n "$(story_field "$id" name)" ]] || fail "No story $id in feature_list.json."
  mkdir -p "$(story_log_dir "$id")"
  rm -f "$(result_file "$id")"
  claim_story "$id" "$dir" || { record "$id" failed "could not create its worktree or start it"; return 1; }
  if [[ "$(worktree_state "$id")" == passing ]]; then
    attempt=$(find "$(story_log_dir "$id")" -name 'implement-*.log' | wc -l | tr -d ' ')
    report "$id: already passing in its worktree after $attempt attempt(s); shipping it"
    passed=true
  fi
  $passed || for (( attempt = 1; attempt <= MAX_ATTEMPTS; attempt++ )); do
    report "$id: implement, attempt $attempt of $MAX_ATTEMPTS ($CLI, session \"$(session_name "$id")\")"
    implement_story "$id" "$dir" "$attempt" "$feedback"
    if [[ "$(worktree_state "$id")" == blocked ]]; then
      record "$id" blocked "$(cd "$dir" && bash "$FEATURE" show "$id" | jq -r .evidence)"
      return 0
    fi
    if ! feedback=$(gate_story "$id" "$dir" "$attempt"); then
      report "$id: gate failed: $(head -n 1 <<< "$feedback")"
      continue
    fi
    report "$id: review ($CHECKER, fresh read-only session)"
    if ! feedback=$(review_story "$id" "$dir" "$attempt"); then
      report "$id: review failed: $(tail -n 1 <<< "$feedback")"
      continue
    fi
    if ! feedback=$(cd "$dir" && bash "$FEATURE" done "$id" 2>&1); then
      feedback="feature.sh done $id refused:"$'\n'"$(tail -n "$FEEDBACK_LINES" <<< "$feedback")"
      continue
    fi
    passed=true
    break
  done
  (( attempt > MAX_ATTEMPTS )) && attempt=$MAX_ATTEMPTS
  if ! $passed; then
    (cd "$dir" && bash "$FEATURE" block "$id" "The runner gave up after $MAX_ATTEMPTS attempts. Last finding: $(head -c 300 <<< "$feedback" | tr '\n' ' ')" > /dev/null)
    record "$id" blocked "gave up after $MAX_ATTEMPTS attempts; see $(story_log_dir "$id")"
    return 0
  fi
  CHECK_LOG=$(ls -t "$(story_log_dir "$id")"/check-*.log 2> /dev/null | head -n 1)
  ship_story "$id" "$dir" "$attempt" || { record "$id" failed "could not commit, push or open the pull request; the worktree $dir is kept"; return 1; }
}

claim_story() {
  local id=$1 dir=$2 branch state
  branch=$(branch_name "$id")
  if [[ -d "$dir" ]]; then
    report "$id: reusing worktree $WORKTREES_DIR/$id"
  elif git show-ref -q --verify "refs/heads/$branch"; then
    git worktree add -q "$dir" "$branch" || return 1
  else
    git worktree add -q -b "$branch" "$dir" HEAD || return 1
  fi
  if [[ -d "$ROOT/$HUSKY_RUNTIME_DIR" && ! -d "$dir/$HUSKY_RUNTIME_DIR" ]]; then
    cp -R "$ROOT/$HUSKY_RUNTIME_DIR" "$dir/$HUSKY_RUNTIME_DIR" || return 1
  fi
  state=$(worktree_state "$id")
  case "$state" in
    not_started | blocked) (cd "$dir" && bash "$FEATURE" start "$id") || return 1 ;;
    active | passing) ;;
    *) report "$id is $state in its worktree."; return 1 ;;
  esac
}

implement_story() {
  local id=$1 dir=$2 attempt=$3 feedback=$4 prompt
  prompt="Session \"$(session_name "$id")\". You are running unattended in a worktree on branch $(branch_name "$id"). Story $id is already active: scripts/agent/feature.sh start ran.
1. Read the story with scripts/agent/feature.sh show $id. If it has a prd field, read only that section of the PRD.
2. Build it with the tdd skill, one acceptance criterion at a time, following docs/agents/add-feature.md. Change only files in its owns and the shared files. The runner checks the commit order: make format, then make your FIRST commit hold only files under $TEST_PATH_PREFIX, with the story's tests, and the story's tests must fail on it. Name it test($id): <what it proves>. Then commit the code as feat($id): <what it does>.
3. Run make format, then make check until it prints CHECK PASSED.
4. Mention $id in PROGRESS.md: what changed, why, and what comes next.
The runner does the rest: the independent review, feature.sh done, the commit, the push and the pull request. Do not run feature.sh done and do not push. Commit only as step 2 says.
You may hand exploration or test drafting to subagents. If something outside the repo stops you, run scripts/agent/feature.sh block $id \"<reason>\" and stop."
  if [[ -n "$feedback" ]]; then
    prompt+=$'\n\n'"This is attempt $attempt of $MAX_ATTEMPTS. The previous attempt did not pass. Fix these findings first:"$'\n'"$feedback"
  fi
  (cd "$dir" && run_session "$CLI" "$MODEL" write "$(session_name "$id")" "$prompt" "$(story_log_dir "$id")/implement-$attempt.log")
}

gate_story() {
  local id=$1 dir=$2 attempt=$3 log_dir output
  log_dir=$(story_log_dir "$id")
  mkdir -p "$dir/$RUNNER_DIR"
  if ! (cd "$dir" && make check > "$log_dir/check-$attempt.log" 2>&1); then
    echo "make check failed. Its last lines:"
    grep -v '^make: \*\*\*' "$log_dir/check-$attempt.log" | tail -n "$FEEDBACK_LINES"
    return 1
  fi
  if ! output=$(cd "$dir" && bash "$FEATURE" scope "$id" 2>&1); then
    echo "$output"
    return 1
  fi
  if ! grep -qwF "$id" "$dir/PROGRESS.md"; then
    echo "PROGRESS.md does not mention $id. Add what $id changed, why, and what comes next."
    return 1
  fi
  tdd_commit_order "$id" "$dir" || return 1
  if ! (cd "$dir" && dotnet test "$(ls ./*.slnx | head -n 1)" --no-build --filter "$(story_field "$id" test_filter)" > "$dir/$RUNNER_DIR/tests.log" 2>&1); then
    echo "The story's tests failed:"
    tail -n "$FEEDBACK_LINES" "$dir/$RUNNER_DIR/tests.log"
    return 1
  fi
  grep -qE 'Passed: +[1-9]' "$dir/$RUNNER_DIR/tests.log" || { echo "The test filter $(story_field "$id" test_filter) matched no tests. Write the story's tests in that class."; return 1; }
}

tdd_commit_order() {
  local id=$1 dir=$2 base first
  base=$(git -C "$dir" merge-base HEAD "$BASE_BRANCH")
  first=$(git -C "$dir" log --reverse --format=%H "$base..HEAD" | sed -n 1p)
  if [[ -z "$first" ]]; then
    echo "TDD rule: there is no commit. Make the first commit hold only the story's tests under $TEST_PATH_PREFIX and fail, then commit the code."
    return 1
  fi
  if ! first_commit_is_tests_only "$dir" "$first"; then
    echo "TDD rule: the first commit must change only files under $TEST_PATH_PREFIX. Undo the history with git reset --soft $base, then commit the story's tests alone as test($id): ..., run make format, and commit the code after it."
    return 1
  fi
  first_commit_fails_tests "$id" "$dir" "$first"
}

first_commit_is_tests_only() {
  local files
  files=$(git -C "$1" diff-tree --no-commit-id --name-only -r "$2")
  [[ -n "$files" ]] && ! grep -qv "^$TEST_PATH_PREFIX" <<< "$files"
}

first_commit_fails_tests() {
  local id=$1 dir=$2 sha=$3 red passed=false
  red="$(story_log_dir "$id")/red"
  rm -rf "$red"
  git -C "$dir" worktree add -q --detach "$red" "$sha" || return 1
  (cd "$red" && dotnet test "$(ls ./*.slnx | head -n 1)" --filter "$(story_field "$id" test_filter)" > "$(story_log_dir "$id")/red.log" 2>&1) && passed=true
  git -C "$dir" worktree remove --force "$red"
  if $passed; then
    echo "TDD rule: the story's tests pass on the first commit, so they prove nothing it added. Make the first commit's tests fail, then add the code in a later commit. Log: $(story_log_dir "$id")/red.log"
    return 1
  fi
}

review_story() {
  local id=$1 dir=$2 attempt=$3 out before after prompt verdict
  out="$(story_log_dir "$id")/review-$attempt.md"
  prompt="Session \"$id · review\". You are the independent reviewer of story $id. You did not write this code. Run the verify skill for $id.
The change is git diff $(git -C "$dir" merge-base HEAD "$BASE_BRANCH") plus the untracked files git status lists.
The runner already ran make check, which passed, and the story's tests. Their output is in $RUNNER_DIR/tests.log: read it instead of building or running the tests.
Do not edit, create or delete any file. End with the VERIFY line."
  before=$(cd "$dir" && bash "$FINGERPRINT")
  (cd "$dir" && run_session "$CHECKER" "$CHECKER_MODEL" read "$id · review" "$prompt" "$out") >&2
  after=$(cd "$dir" && bash "$FINGERPRINT")
  if [[ "$before" != "$after" ]]; then
    echo "The reviewer changed files, so its review does not count. Undo any change it made."
    return 1
  fi
  verdict=$(verdict_of "$out")
  cat "$out" > "$dir/$RUNNER_DIR/review.md"
  [[ "$verdict" == "VERIFY: PASS" ]] && return 0
  echo "The independent review failed (${verdict:-no VERIFY line}). Its report:"
  tail -n "$FEEDBACK_LINES" "$out"
  return 1
}

ship_story() {
  local id=$1 dir=$2 attempts=$3 branch subject issue body url
  branch=$(branch_name "$id")
  subject="feat($id): $(lowercase_first "$(story_field "$id" name)")"
  (
    cd "$dir" || exit 1
    git add -A && { git diff --cached --quiet || git commit -q -m "$subject" -m "$(story_field "$id" title)"; } && git push -q -u origin "$branch"
  ) || return 1
  issue=$(bash "$SYNC" issue "$id" 2> /dev/null || true)
  body=$(pull_request_body "$id" "$dir" "$attempts" "$issue")
  url=$(gh pr create --base "$BASE_BRANCH" --head "$branch" --title "$subject" --body "$body") || return 1
  git worktree remove "$dir" || report "$id: kept the worktree $dir; remove it with git worktree remove."
  record "$id" shipped "$url"
}

pull_request_body() {
  local id=$1 dir=$2 attempts=$3 issue=$4
  bash "$FEATURE" show "$id" | jq -r '"## \(.id) · \(.name)\n\(.title)\n\n### Acceptance criteria\n" + ([.acceptance_criteria[] | "- [x] \(.)"] | join("\n"))'
  printf '\n### Independent review (%s, fresh session)\n' "$CHECKER"
  sed -n '/^|/,$p' "$dir/$RUNNER_DIR/review.md"
  printf '\n\n### Evidence\n- `%s`\n- `feature.sh done`: %s\n- Implemented by %s in session "%s", %s attempt(s).\n' \
    "$(grep -m 1 'CHECK PASSED' "$CHECK_LOG" 2> /dev/null || echo 'make check passed')" \
    "$(cd "$dir" && bash "$FEATURE" show "$id" | jq -r .evidence)" "$CLI" "$(session_name "$id")" "$attempts"
  [[ -n "$issue" ]] && printf '\nCloses #%s\n' "$issue"
}

merge_wave() {
  local id url
  for id in $1; do
    url=$(result_of "$id" shipped) || continue
    merge_pull_request "$id" "$url" || return 1
  done
}

wait_for_checks() {
  local round
  for (( round = 0; round < CHECKS_APPEAR_ROUNDS; round++ )); do
    [[ "$(gh pr view "$1" --json statusCheckRollup --jq '.statusCheckRollup | length')" != 0 ]] && return 0
    sleep "$POLL_SECONDS"
  done
}

merge_pull_request() {
  local id=$1 url=$2 state round
  wait_for_checks "$url"
  for round in 1 2 3; do
    gh pr checks "$url" --watch --fail-fast --interval "$POLL_SECONDS" > /dev/null 2>&1 || {
      report "$id: CI failed on $url. Not merged; the run stops here."
      return 1
    }
    state=$(gh pr view "$url" --json mergeStateStatus --jq .mergeStateStatus)
    case "$state" in
      CLEAN | HAS_HOOKS | UNSTABLE)
        gh pr merge "$url" --squash --delete-branch --match-head-commit "$(gh pr view "$url" --json headRefOid --jq .headRefOid)" > /dev/null || return 1
        git pull -q --ff-only
        bash "$SYNC" push "$id" > /dev/null || true
        report "$id: merged $url"
        return 0 ;;
      BEHIND) gh pr update-branch "$url" > /dev/null || resolve_conflicts "$id" || return 1 ;;
      DIRTY) resolve_conflicts "$id" || return 1 ;;
      *) sleep "$POLL_SECONDS" ;;
    esac
  done
  report "$id: $url is still not mergeable ($state). Not merged; the run stops here."
  return 1
}

resolve_conflicts() {
  local id=$1 dir="$ROOT/$WORKTREES_DIR/$1" branch
  branch=$(branch_name "$id")
  git fetch -q origin "$BASE_BRANCH" "$branch"
  [[ -d "$dir" ]] || git worktree add -q "$dir" "$branch" || return 1
  (cd "$dir" && git merge -q --ff-only "origin/$branch" 2> /dev/null)
  report "$id: resolving conflicts with $BASE_BRANCH ($CLI, session \"$id · merge $BASE_BRANCH\")"
  (cd "$dir" && run_session "$CLI" "$MODEL" write "$id · merge $BASE_BRANCH" "Session \"$id · merge $BASE_BRANCH\". Run git merge origin/$BASE_BRANCH in this worktree and resolve every conflict so both sides keep working. Run make check until it prints CHECK PASSED, then commit the merge. Do not push." "$(story_log_dir "$id")/resolve.log")
  (cd "$dir" && git merge-base --is-ancestor "origin/$BASE_BRANCH" HEAD && make check > /dev/null 2>&1 && git push -q origin "$branch") || {
    report "$id: conflicts are not resolved; see $(story_log_dir "$id")/resolve.log and the worktree $dir."
    return 1
  }
  git worktree remove "$dir" > /dev/null 2>&1 || true
}

default_checker_model() {
  case "$1" in
    copilot) echo "$COPILOT_DEFAULT_CHECKER_MODEL" ;;
    *) default_model "$1" ;;
  esac
}

default_model() {
  case "$1" in
    claude) echo "$CLAUDE_DEFAULT_MODEL" ;;
    codex) echo "$CODEX_DEFAULT_MODEL" ;;
    copilot) echo "$COPILOT_DEFAULT_MODEL" ;;
  esac
}

run_session() {
  local cli=$1 model=$2 mode=$3 name=$4 prompt=$5 out=$6
  case "$cli:$mode" in
    claude:write)
      claude -p "$prompt" --model "$model" -n "$name" --permission-mode bypassPermissions --disallowedTools "Bash(git push *)" < /dev/null 2>&1 | tee "$out" ;;
    claude:read)
      claude -p "$prompt" --model "$model" -n "$name" --disallowedTools Edit Write NotebookEdit "Bash(make format)" "Bash(dotnet format *)" \
        "Bash(scripts/agent/feature.sh start *)" "Bash(scripts/agent/feature.sh done *)" "Bash(scripts/agent/feature.sh block *)" \
        "Bash(scripts/agent/feature.sh add *)" < /dev/null 2>&1 | tee "$out" ;;
    codex:write)
      codex exec -m "$model" --dangerously-bypass-approvals-and-sandbox "$prompt" < /dev/null 2>&1 | tee "$out" ;;
    codex:read)
      codex exec -m "$model" --sandbox read-only -o "$out" "$prompt" < /dev/null > "$out.log" 2>&1
      tail -n 20 "$out" ;;
    copilot:write)
      copilot -p "$prompt" --model "$model" -n "$name" --allow-all --no-ask-user --deny-tool 'shell(git push)' 2>&1 | tee "$out" ;;
    copilot:read)
      copilot -p "$prompt" --model "$model" -n "$name" -s --no-ask-user --deny-tool write \
        --allow-tool 'shell(git diff:*)' --allow-tool 'shell(git status:*)' --allow-tool 'shell(git log:*)' --allow-tool 'shell(git show:*)' \
        --allow-tool 'shell(scripts/agent/feature.sh show:*)' --allow-tool 'shell(scripts/agent/feature.sh scope:*)' 2>&1 | tee "$out" ;;
  esac
}

verdict_of() {
  grep -oE 'VERIFY: (PASS|FAIL[^`*]*)' "$1" 2> /dev/null | tail -n 1 | sed -E 's/[[:space:]]+$//'
}

open_pull_request() {
  gh pr list --state open --head "$(branch_name "$1")" --json url --jq '.[0].url // empty' 2> /dev/null
}

worktree_state() {
  local dir="$ROOT/$WORKTREES_DIR/$1"
  [[ -d "$dir" ]] || return 0
  (cd "$dir" && bash "$FEATURE" show "$1" 2> /dev/null | jq -r .state)
}

story_field() {
  bash "$FEATURE" show "$1" 2> /dev/null | jq -r --arg field "$2" '.[$field] // empty'
}

session_name() {
  echo "$1 · $(story_field "$1" name)"
}

branch_name() {
  echo "feat/$(slug "$1-$(story_field "$1" name)")"
}

slug() {
  tr '[:upper:]' '[:lower:]' <<< "$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c "1-$SLUG_MAX_LENGTH" | sed -E 's/-+$//'
}

lowercase_first() {
  echo "$(tr '[:upper:]' '[:lower:]' <<< "${1:0:1}")${1:1}"
}

default_branch() {
  git symbolic-ref -q --short refs/remotes/origin/HEAD 2> /dev/null | sed 's|^origin/||' || echo main
}

story_log_dir() {
  echo "$ROOT/$RUNS_DIR/$1"
}

result_file() {
  echo "$ROOT/$RUNS_DIR/$1/result"
}

record() {
  mkdir -p "$(story_log_dir "$1")"
  echo "$2 $3" > "$(result_file "$1")"
  report "$1: $2 $3"
}

result_of() {
  local line
  line=$(cat "$(result_file "$1")" 2> /dev/null) || return 1
  [[ "$line" == "$2 "* ]] || return 1
  echo "${line#"$2 "}"
}

print_results() {
  local id
  echo "Results:"
  for id in $1; do echo "  $id: $(cat "$(result_file "$id")" 2> /dev/null || echo 'no result')"; done
}

report() {
  echo "run: $1" >&2
}

fail() {
  echo "$1" >&2
  exit 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
