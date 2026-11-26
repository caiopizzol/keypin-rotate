#!/usr/bin/env bash
# Restores .keypin/ from the state branch into the checkout, and outputs the commit it came from.
# Without the branch, it outputs an empty commit and keypin starts with no state.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

if [ -e .keypin ] || [ -L .keypin ]; then
  echo "::error::.keypin already exists in the checkout. Keep it on $STATE_BRANCH only."
  exit 1
fi

status=0
git ls-remote --exit-code origin "refs/heads/$STATE_BRANCH" > /dev/null || status=$?
if [ "$status" = 2 ]; then
  echo "::notice::$STATE_BRANCH doesn't exist yet, so keypin starts with no state. This run creates it."
  output commit ""
  exit 0
elif [ "$status" != 0 ]; then
  echo "::error::Couldn't read $STATE_BRANCH from origin."
  exit 1
fi

git fetch --quiet --no-tags origin "+refs/heads/$STATE_BRANCH:refs/keypin/state"
commit=$(git rev-parse --verify "refs/keypin/state^{commit}")
mkdir .keypin
for file in rotation.json status.json; do
  mode=$(git ls-tree "$commit" -- ".keypin/$file" | cut -d' ' -f1)
  if [ "$mode" != 100644 ]; then
    echo "::error::.keypin/$file on $STATE_BRANCH isn't a regular file (mode '$mode')"
    exit 1
  fi
  git cat-file blob "$commit:.keypin/$file" > ".keypin/$file"
done
echo "Restored .keypin/ from $STATE_BRANCH at $commit."
output commit "$commit"
