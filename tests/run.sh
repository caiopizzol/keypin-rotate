#!/usr/bin/env bash
# Runs the action's scripts in action.yml's order, against a local bare repository as origin, with
# curl, keypin and gh stubbed. No network. Usage: tests/run.sh [test name...]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BRANCH=keypin/state
ARTIFACT=keypin-state-1-1
failures=0

# Every script action.yml runs, except the install, must run here too.
while read -r script; do
  [ "$script" = scripts/install-keypin.sh ] && continue
  grep -q "${script#scripts/}" "$0" || {
    echo "tests/run.sh doesn't run $script"
    exit 1
  }
done < <(grep -o 'scripts/[a-z-]*\.sh' "$ROOT/action.yml" | sort -u)

# Fresh origin with a default branch, a stub log and a git config of its own.
setup() {
  T=$(mktemp -d)
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.name test
  git config --global user.email test@example.com
  git config --global init.defaultBranch main
  git init --quiet --bare "$T/origin.git"
  git clone --quiet "$T/origin.git" "$T/seed" 2> /dev/null
  echo "# acme/web" > "$T/seed/README.md"
  git -C "$T/seed" add README.md
  git -C "$T/seed" commit --quiet -m "chore: start"
  git -C "$T/seed" push --quiet origin HEAD:refs/heads/main
  export STUB_DIR="$T/stub" STUB_LOG="$T/stub/log"
  mkdir -p "$STUB_DIR"
  unset STUB_ROTATION STUB_STATUS STUB_CLAIM STUB_REPORT STUB_OIDC_FAIL_FROM STUB_ON_ROTATE \
    STUB_ROTATE_EXIT STUB_REVOKE_EXIT STUB_TOKEN_RESPONSE ON_CHECKOUT
}

# Pushes .keypin/ with the given rotation.json to the state branch, as an earlier run would.
seed_state() {
  git -C "$T/seed" switch --quiet --orphan state-seed
  mkdir -p "$T/seed/.keypin"
  cp "$1" "$T/seed/.keypin/rotation.json"
  echo '{"rotated":{}}' > "$T/seed/.keypin/status.json"
  git -C "$T/seed" add .keypin
  git -C "$T/seed" commit --quiet -m "chore: record key rotation"
  git -C "$T/seed" push --quiet origin "HEAD:refs/heads/$BRANCH"
}

# Pushes one more commit to the state branch, as another run would. Creates the branch if needed.
move_state() {
  local other="$T/other-$RANDOM"
  git clone --quiet "$T/origin.git" "$other" 2> /dev/null
  if git -C "$other" fetch --quiet origin "$BRANCH" 2> /dev/null; then
    git -C "$other" switch --quiet --detach FETCH_HEAD
  else
    git -C "$other" switch --quiet --orphan moved
  fi
  mkdir -p "$other/.keypin"
  echo '{"issued":[],"by":"another run"}' > "$other/.keypin/rotation.json"
  echo '{"rotated":{}}' > "$other/.keypin/status.json"
  git -C "$other" add .keypin
  git -C "$other" commit --quiet -m "chore: another run"
  git -C "$other" push --quiet origin "HEAD:refs/heads/$BRANCH"
}

# Makes the keypin stub move the state branch while it rotates.
move_during_rotation() {
  { declare -f move_state; echo "T='$T' BRANCH='$BRANCH' move_state"; } > "$T/move.sh"
  export STUB_ON_ROTATE="$T/move.sh"
}

remote_state() {
  git -C "$T/origin.git" rev-parse --verify --quiet "refs/heads/$BRANCH" || true
}

# Prints a step's output from its GITHUB_OUTPUT file.
output_of() {
  sed -n "s/^$2=//p" "$RUNNER_TEMP/output-$1" 2> /dev/null | tail -n 1
}

# Runs one script in the workspace with the given env, appending what it prints to $T/out.
step() {
  local id=$1 script=$2
  shift 2
  : > "$RUNNER_TEMP/output-$id"
  echo "step $id" >> "$STUB_LOG"
  (cd "$T/workspace" && env GITHUB_OUTPUT="$RUNNER_TEMP/output-$id" "$@" "$ROOT/scripts/$script") >> "$T/out" 2>&1
}

# Mirrors action.yml: a failed step skips the next ones, except those that run always().
run_action() {
  local check=${1:-false} ok=true restore=skipped staged="" save=skipped restored commit
  export RUNNER_TEMP="$T/runner"
  rm -rf "$RUNNER_TEMP" "$T/workspace" "$T/oidc-count" "$STUB_DIR/oidc-count"
  mkdir -p "$RUNNER_TEMP"
  : > "$T/out"
  export PATH="$ROOT/tests/stubs:$PATH" SAVE_RETRY_DELAY=0
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.test/token?run=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token
  local op=OP_SERVICE_ACCOUNT_TOKEN=op-stub state="STATE_BRANCH=$BRANCH"

  git clone --quiet "$T/origin.git" "$T/workspace" 2> /dev/null # actions/checkout, which runs second
  if [ -n "${ON_CHECKOUT:-}" ]; then (cd "$T/workspace" && bash -c "$ON_CHECKOUT"); fi
  step inputs check-inputs.sh CHECK_SETUP="$check" KEYPIN_VERSION=0.46.1 "$state" "$op" || return 1
  if step restore restore-state.sh "$state"; then restore=success; else ok=false; fi
  restored=$(output_of restore commit)
  $ok && { step token github-token.sh || ok=false; }
  if $ok && [ "$check" != true ]; then
    step claim claim-revokes.sh "$state" KEYPIN_1PASSWORD=service-account "$op" || ok=false
  fi
  $ok && { step rotate rotate.sh CHECK_SETUP="$check" KEYPIN_1PASSWORD=service-account "$op" || ok=false; }
  if [ "$restore" = success ]; then
    step stage stage-state.sh RESTORED="$restored" || ok=false
    staged=$(output_of stage staged)
  fi
  if [ "$staged" = true ]; then
    echo "upload-artifact $ARTIFACT" >> "$STUB_LOG"
    if step save save-state.sh "$state" RESTORED="$restored" ARTIFACT="$ARTIFACT"; then
      save=success
    else
      ok=false
    fi
  fi
  commit=$(output_of save commit)
  echo "$commit" > "$T/state-commit"
  if [ "$check" != true ] && [ "$save" = success ]; then
    step report report.sh COMMIT="$commit" || ok=false
  fi
  $ok
}

# Records a failed check; the test goes on, so one run shows every failed check.
fail() {
  echo "  FAIL: $*" >> "$T/failed"
}
has() { grep -qF -- "$2" "$1" || fail "expected '$2' in $1"; }
lacks() { ! grep -qF -- "$2" "$1" || fail "didn't expect '$2' in $1"; }
same() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }

# rotation.json with one rotated key whose old key waits for revoke.
waiting_rotation() {
  cat > "$1" << 'EOF'
{"issued":[
  {"key":"OPENAI_API_KEY","environment":"production","issuer":"openai","id":"key-new","at":"2026-11-01T09:17:00Z","old":{"id":"key-old"}},
  {"key":"RESEND_API_KEY","environment":"preview","issuer":"resend","id":"re-new","at":"2026-11-02T09:17:00Z","old":{"id":"re-old"}}
]}
EOF
}

test_first_run_creates_the_state_branch() {
  waiting_rotation "$T/rotation.json"
  export STUB_ROTATION="$T/rotation.json"
  run_action || fail "the run failed"
  local commit
  commit=$(remote_state)
  [ -n "$commit" ] || fail "no $BRANCH on origin"
  same "$(cat "$T/state-commit")" "$commit"
  same "$(git -C "$T/origin.git" show "$commit:.keypin/rotation.json")" "$(cat "$T/rotation.json")"
  same "$(git -C "$T/origin.git" rev-list --count "$commit")" 1
  has "$T/out" "doesn't exist yet"
  lacks "$STUB_LOG" "keypin had state"
  has "$STUB_LOG" "keypin rotate --due --yes 1password=service-account op=op-stub gh=$T/runner/keypin-rotate/gh"
  has "$STUB_LOG" "gh auth login gh=$T/runner/keypin-rotate/gh token=ok"
  has "$STUB_LOG" "curl oidc &audience=https://keypin.dev auth=request-token"
  has "$STUB_LOG" "curl keypin.dev rotation-report auth=oidc-jwt data={\"commit\":\"$commit\"}"
  has "$T/out" "::notice::The old OPENAI_API_KEY still works."
}

test_second_run_restores_and_pushes_nothing() {
  waiting_rotation "$T/rotation.json"
  export STUB_ROTATION="$T/rotation.json"
  run_action || fail "the first run failed"
  local first
  first=$(remote_state)
  : > "$STUB_LOG"
  run_action || fail "the second run failed"
  has "$STUB_LOG" "keypin had state"
  same "$(remote_state)" "$first"
  same "$(cat "$T/state-commit")" "$first"
  has "$T/out" "didn't change"
  has "$STUB_LOG" "curl keypin.dev rotation-report auth=oidc-jwt data={\"commit\":\"$first\"}"
}

test_a_change_is_pushed_on_top_of_the_restored_commit() {
  echo '{"issued":[]}' > "$T/old.json"
  seed_state "$T/old.json"
  local restored
  restored=$(remote_state)
  waiting_rotation "$T/rotation.json"
  export STUB_ROTATION="$T/rotation.json"
  run_action || fail "the run failed"
  same "$(git -C "$T/origin.git" rev-parse "$(remote_state)^")" "$restored"
  same "$(cat "$T/state-commit")" "$(remote_state)"
}

test_a_moved_state_branch_fails_the_save() {
  echo '{"issued":[]}' > "$T/old.json"
  seed_state "$T/old.json"
  waiting_rotation "$T/rotation.json"
  export STUB_ROTATION="$T/rotation.json"
  move_during_rotation
  if run_action; then fail "the run passed"; fi
  local moved
  moved=$(remote_state)
  same "$(git -C "$T/origin.git" show "$moved:.keypin/rotation.json")" '{"issued":[],"by":"another run"}'
  has "$T/out" "::error::$BRANCH moved after this run restored it"
  has "$T/out" "$ARTIFACT artifact"
  has "$STUB_LOG" "upload-artifact $ARTIFACT"
  same "$(cat "$T/runner/keypin-rotate/state/rotation.json")" "$(cat "$T/rotation.json")"
  lacks "$STUB_LOG" "rotation-report"
}

test_a_branch_created_during_a_first_run_fails_the_save() {
  waiting_rotation "$T/rotation.json"
  export STUB_ROTATION="$T/rotation.json"
  move_during_rotation
  if run_action; then fail "the run passed"; fi
  has "$T/out" "from 'no branch' to"
  lacks "$STUB_LOG" "rotation-report"
}

test_failed_rotation_still_saves_and_reports() {
  waiting_rotation "$T/rotation.json"
  export STUB_ROTATION="$T/rotation.json" STUB_ROTATE_EXIT=1
  if run_action; then fail "the run passed"; fi
  [ -n "$(remote_state)" ] || fail "no $BRANCH on origin"
  has "$STUB_LOG" "rotation-report"
}

test_oidc_failure_in_claim_warns_and_rotation_runs() {
  waiting_rotation "$T/rotation.json"
  seed_state "$T/rotation.json"
  export STUB_ROTATION="$T/rotation.json" STUB_OIDC_FAIL_FROM=2
  run_action || fail "the run failed"
  has "$T/out" "::warning::Couldn't get approved revokes from keypin.dev"
  lacks "$STUB_LOG" "revokes/claim"
  has "$STUB_LOG" "keypin rotate --due --yes"
  has "$T/out" "::warning::keypin.dev didn't record this run's state"
}

test_claim_error_warns_and_rotation_runs() {
  waiting_rotation "$T/rotation.json"
  seed_state "$T/rotation.json"
  export STUB_ROTATION="$T/rotation.json" STUB_CLAIM='{"error":"Not claimed: no installation."}'
  run_action || fail "the run failed"
  has "$T/out" "revokes nothing. Not claimed: no installation."
  has "$STUB_LOG" "keypin rotate --due --yes"
}

test_matching_approvals_are_revoked() {
  waiting_rotation "$T/rotation.json"
  seed_state "$T/rotation.json"
  export STUB_ROTATION="$T/rotation.json"
  export STUB_CLAIM='{"revokes":[
    {"key":"OPENAI_API_KEY","environment":"production","newId":"key-new","oldId":"key-old","issuedAt":"2026-11-01T09:17:00Z"},
    {"key":"RESEND_API_KEY","environment":"preview","newId":"re-new","oldId":"re-old","issuedAt":"2026-11-02T09:17:00Z"}]}'
  run_action || fail "the run failed"
  has "$STUB_LOG" "keypin rotate --approve-revoke OPENAI_API_KEY --profile production 1password=service-account op=op-stub"
  has "$STUB_LOG" "keypin rotate --approve-revoke RESEND_API_KEY --profile preview"
  lacks "$T/out" "::warning::"
  # Revokes run before rotation.
  [ "$(grep -n 'approve-revoke RESEND' "$STUB_LOG" | cut -d: -f1)" -lt "$(grep -n 'rotate --due' "$STUB_LOG" | cut -d: -f1)" ] ||
    fail "a revoke ran after rotation"
}

test_mismatched_approvals_are_skipped() {
  waiting_rotation "$T/rotation.json"
  seed_state "$T/rotation.json"
  export STUB_ROTATION="$T/rotation.json"
  export STUB_CLAIM='{"revokes":[
    {"key":"OPENAI_API_KEY","environment":"production","newId":"key-new","oldId":"key-old","issuedAt":"2026-10-01T09:17:00Z"},
    {"key":"RESEND_API_KEY","environment":"production","newId":"re-new","oldId":"re-old","issuedAt":"2026-11-02T09:17:00Z"},
    {"key":"OPENAI_API_KEY; rm -rf /","environment":"production","newId":"key-new","oldId":"key-old","issuedAt":"2026-11-01T09:17:00Z"},
    {"key":"OPENAI_API_KEY","environment":"production"}]}'
  run_action || fail "the run failed"
  lacks "$STUB_LOG" "approve-revoke"
  has "$T/out" "::warning::Skipped OPENAI_API_KEY (production): $BRANCH no longer matches what was approved."
  has "$T/out" "::warning::Skipped RESEND_API_KEY (production)"
  has "$T/out" "::warning::Skipped an approved revoke with an unexpected key or profile name."
  has "$STUB_LOG" "keypin rotate --due --yes"
}

test_a_revoked_old_key_is_skipped() {
  cat > "$T/rotation.json" << 'EOF'
{"issued":[{"key":"OPENAI_API_KEY","environment":"production","id":"key-new","at":"2026-11-01T09:17:00Z","old":{"id":"key-old","revoked":"2026-11-03T09:17:00Z"}}]}
EOF
  seed_state "$T/rotation.json"
  export STUB_CLAIM='{"revokes":[{"key":"OPENAI_API_KEY","environment":"production","newId":"key-new","oldId":"key-old","issuedAt":"2026-11-01T09:17:00Z"}]}'
  run_action || fail "the run failed"
  lacks "$STUB_LOG" "approve-revoke"
}

test_a_failed_revoke_warns() {
  waiting_rotation "$T/rotation.json"
  seed_state "$T/rotation.json"
  export STUB_ROTATION="$T/rotation.json" STUB_REVOKE_EXIT=1
  export STUB_CLAIM='{"revokes":[{"key":"OPENAI_API_KEY","environment":"production","newId":"key-new","oldId":"key-old","issuedAt":"2026-11-01T09:17:00Z"}]}'
  run_action || fail "the run failed"
  has "$T/out" "::warning::Revoking the old OPENAI_API_KEY (production) failed"
  has "$STUB_LOG" "keypin rotate --due --yes"
}

test_check_setup_skips_claim_and_report() {
  waiting_rotation "$T/rotation.json"
  seed_state "$T/rotation.json"
  local before
  before=$(remote_state)
  run_action true || fail "the run failed"
  has "$STUB_LOG" "keypin rotate --check"
  lacks "$STUB_LOG" "rotate --due"
  lacks "$STUB_LOG" "revokes/claim"
  lacks "$STUB_LOG" "rotation-report"
  same "$(remote_state)" "$before"
}

test_check_setup_on_a_first_run_saves_nothing() {
  run_action true || fail "the run failed"
  same "$(remote_state)" ""
  lacks "$STUB_LOG" "upload-artifact"
  has "$T/out" "nothing to save"
}

test_no_github_token_stops_rotation_and_keeps_state() {
  waiting_rotation "$T/rotation.json"
  seed_state "$T/rotation.json"
  local before
  before=$(remote_state)
  export STUB_TOKEN_RESPONSE='{"error":"No token: keypin-app isn'"'"'t installed on acme/web."}'
  if run_action; then fail "the run passed"; fi
  has "$T/out" "::error::keypin.dev gave no GitHub token. No token: keypin-app isn't installed on acme/web."
  lacks "$STUB_LOG" "keypin rotate"
  same "$(remote_state)" "$before"
}

test_a_symlinked_state_file_is_refused() {
  git -C "$T/seed" switch --quiet --orphan state-seed
  mkdir -p "$T/seed/.keypin"
  ln -s /etc/hosts "$T/seed/.keypin/rotation.json"
  echo '{}' > "$T/seed/.keypin/status.json"
  git -C "$T/seed" add .keypin
  git -C "$T/seed" commit --quiet -m "chore: bad state"
  git -C "$T/seed" push --quiet origin "HEAD:refs/heads/$BRANCH"
  local before
  before=$(remote_state)
  if run_action; then fail "the run passed"; fi
  has "$T/out" "isn't a regular file (mode '120000')"
  lacks "$STUB_LOG" "keypin rotate"
  same "$(remote_state)" "$before"
}

# Commits .keypin/ to the default branch, as keypin's free workflow keeps it. $1 is rotation.json's
# content; with $2 = link, rotation.json is a symlink instead.
commit_keypin_on_main() {
  mkdir -p "$T/seed/.keypin"
  if [ "${2:-}" = link ]; then
    ln -s /etc/hosts "$T/seed/.keypin/rotation.json"
  else
    echo "$1" > "$T/seed/.keypin/rotation.json"
  fi
  echo '{"rotated":{}}' > "$T/seed/.keypin/status.json"
  git -C "$T/seed" add .keypin
  git -C "$T/seed" commit --quiet -m "chore: record key rotation"
  git -C "$T/seed" push --quiet origin HEAD:refs/heads/main
}

test_a_first_run_seeds_state_from_the_default_branch() {
  commit_keypin_on_main '{"issued":[],"from":"main"}'
  # Restore reads the commit, not the working tree.
  export ON_CHECKOUT='echo "{\"issued\":[],\"from\":\"working tree\"}" > .keypin/rotation.json'
  run_action || fail "the run failed"
  local commit
  commit=$(remote_state)
  [ -n "$commit" ] || fail "no $BRANCH on origin"
  same "$(git -C "$T/origin.git" show "$commit:.keypin/rotation.json")" '{"issued":[],"from":"main"}'
  same "$(git -C "$T/origin.git" rev-list --count "$commit")" 1
  has "$STUB_LOG" "keypin had state"
  has "$T/out" "keypin starts from .keypin/ on the default branch"
  has "$STUB_LOG" "curl keypin.dev rotation-report auth=oidc-jwt data={\"commit\":\"$commit\"}"
}

test_the_state_branch_wins_over_the_default_branch() {
  commit_keypin_on_main '{"issued":[],"from":"main"}'
  echo '{"issued":[],"from":"state"}' > "$T/state.json"
  seed_state "$T/state.json"
  local before
  before=$(remote_state)
  run_action || fail "the run failed"
  same "$(cat "$T/workspace/.keypin/rotation.json")" '{"issued":[],"from":"state"}'
  has "$T/out" "keypin uses $BRANCH and ignores the default branch's copy"
  same "$(remote_state)" "$before"
}

test_a_symlink_in_the_default_branch_keypin_is_refused() {
  commit_keypin_on_main "" link
  if run_action; then fail "the run passed"; fi
  has "$T/out" ".keypin/rotation.json on the default branch isn't a regular file (mode '120000')"
  lacks "$STUB_LOG" "keypin rotate"
  same "$(remote_state)" ""
}

test_inputs_are_checked() {
  export RUNNER_TEMP="$T/runner" GITHUB_OUTPUT=/dev/null
  mkdir -p "$RUNNER_TEMP"
  if CHECK_SETUP=yes KEYPIN_VERSION=latest STATE_BRANCH="bad..branch" OP_SERVICE_ACCOUNT_TOKEN="" \
    "$ROOT/scripts/check-inputs.sh" > "$T/out" 2>&1; then
    fail "bad inputs passed"
  fi
  has "$T/out" "check-setup must be true or false"
  has "$T/out" "keypin-version must be an exact version"
  has "$T/out" "state-branch must be a branch name"
  has "$T/out" "op-service-account-token is empty"
}

tests=("$@")
if [ ${#tests[@]} = 0 ]; then
  while read -r name; do tests+=("${name#test_}"); done < <(declare -F | awk '{print $3}' | grep '^test_')
fi
for name in "${tests[@]}"; do
  setup
  ("test_$name") > "$T/test-out" 2>&1 || echo "  FAIL: the test stopped early" >> "$T/failed"
  if [ -e "$T/failed" ]; then
    echo "FAIL $name"
    cat "$T/failed" "$T/test-out"
    echo "  --- output"
    sed 's/^/  | /' "$T/out" 2> /dev/null || true
    echo "  --- stub log"
    sed 's/^/  | /' "$STUB_LOG" 2> /dev/null || true
    failures=$((failures + 1))
  else
    echo "ok   $name"
  fi
  rm -rf "$T"
done
echo "${#tests[@]} tests, $failures failed"
[ "$failures" = 0 ]
