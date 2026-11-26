#!/usr/bin/env bash
# Commits the staged state on top of the restored commit and pushes it to the state branch,
# only while the branch is still at that commit. Outputs the state commit.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

branch="refs/heads/$STATE_BRANCH"
export GIT_INDEX_FILE="$WORK/index"
rm -f "$GIT_INDEX_FILE"
if [ -n "$RESTORED" ]; then
  git read-tree "$RESTORED"
else
  git read-tree --empty
fi
for file in rotation.json status.json; do
  blob=$(git hash-object -w -- "$STAGED/$file")
  git update-index --add --cacheinfo "100644,$blob,.keypin/$file"
done
tree=$(git write-tree)

if [ -n "$RESTORED" ] && [ "$tree" = "$(git rev-parse "$RESTORED^{tree}")" ]; then
  echo "keypin state didn't change; $STATE_BRANCH stays at $RESTORED."
  output commit "$RESTORED"
  exit 0
fi

export GIT_AUTHOR_NAME=keypin GIT_AUTHOR_EMAIL=keypin@users.noreply.github.com
export GIT_COMMITTER_NAME=keypin GIT_COMMITTER_EMAIL=keypin@users.noreply.github.com
message="chore: record key rotation"
if [ -n "$RESTORED" ]; then
  commit=$(git commit-tree "$tree" -p "$RESTORED" -m "$message")
else
  commit=$(git commit-tree "$tree" -m "$message")
fi

# --force-with-lease with an explicit value pushes only if the branch is still at RESTORED, or
# with RESTORED empty, only if it doesn't exist. A rejected push is retried only while the branch
# hasn't moved, since then the failure was something else, such as the network.
for attempt in 1 2 3; do
  if git push --quiet --force-with-lease="$branch:$RESTORED" origin "$commit:$branch"; then
    echo "Saved keypin state to $STATE_BRANCH at $commit."
    output commit "$commit"
    exit 0
  fi
  if remote=$(git ls-remote origin "$branch"); then
    remote=${remote%%[[:space:]]*}
    if [ "$remote" = "$commit" ]; then
      echo "Saved keypin state to $STATE_BRANCH at $commit."
      output commit "$commit"
      exit 0
    fi
    if [ "$remote" != "$RESTORED" ]; then
      echo "::error::$STATE_BRANCH moved after this run restored it (from '${RESTORED:-no branch}' to '${remote:-no branch}'), so keypin didn't overwrite it. This run's state is in the $ARTIFACT artifact: compare the two, and push the one to keep."
      exit 1
    fi
  fi
  [ "$attempt" = 3 ] || sleep "${SAVE_RETRY_DELAY:-10}"
done
echo "::error::Couldn't save keypin state to $STATE_BRANCH. Restore it from the $ARTIFACT artifact."
exit 1
