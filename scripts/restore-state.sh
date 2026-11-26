#!/usr/bin/env bash
# Restores .keypin/ from the state branch into the checkout, and outputs the commit it came from.
# Without the branch, it seeds .keypin/ from the default branch's commit if .keypin/ is committed
# there, or else starts with no state, and outputs an empty commit so the save creates the branch.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

committed=false
if [ -e .keypin ] || [ -L .keypin ]; then committed=true; fi

status=0
git ls-remote --exit-code origin "refs/heads/$STATE_BRANCH" > /dev/null || status=$?
if [ "$status" = 2 ]; then
  if ! $committed; then
    echo "::notice::$STATE_BRANCH doesn't exist yet, so keypin starts with no state. This run creates it."
    output commit ""
    exit 0
  fi
  source=$(git rev-parse --verify "HEAD^{commit}")
  from="the default branch"
  restored=""
  echo "::notice::$STATE_BRANCH doesn't exist yet, so keypin starts from .keypin/ on the default branch. This run creates $STATE_BRANCH."
elif [ "$status" = 0 ]; then
  git fetch --quiet --no-tags origin "+refs/heads/$STATE_BRANCH:refs/keypin/state"
  source=$(git rev-parse --verify "refs/keypin/state^{commit}")
  from=$STATE_BRANCH
  restored=$source
  if $committed; then
    echo "::notice::.keypin/ is on both the default branch and $STATE_BRANCH. keypin uses $STATE_BRANCH and ignores the default branch's copy."
  fi
else
  echo "::error::Couldn't read $STATE_BRANCH from origin."
  exit 1
fi

# Rebuild .keypin/ from the commit's blobs, never from files already in the working tree.
rm -rf .keypin
mkdir .keypin
for file in rotation.json status.json; do
  mode=$(git ls-tree "$source" -- ".keypin/$file" | cut -d' ' -f1)
  # keypin writes rotation.json only once it has something to record.
  [ -n "$mode" ] || continue
  if [ "$mode" != 100644 ]; then
    echo "::error::.keypin/$file on $from isn't a regular file (mode '$mode')"
    exit 1
  fi
  git cat-file blob "$source:.keypin/$file" > ".keypin/$file"
done
if [ -n "$restored" ] && [ -z "$(ls -A .keypin)" ]; then
  echo "::error::$STATE_BRANCH has neither .keypin/rotation.json nor .keypin/status.json. Check state-branch, or restore the files from an earlier commit or a keypin-state artifact."
  exit 1
fi
echo "Restored .keypin/ from $from at $source."
output commit "$restored"
