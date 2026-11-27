#!/usr/bin/env bash
# Gets a GitHub token from keypin.dev and signs gh in with it, for keypin to publish keys. Outputs
# reported=true or false when keypin.dev says whether this repository reported to it before, and
# nothing when it doesn't say.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

if ! response=$(keypin_dev_post github-token); then
  echo "::error::Couldn't reach keypin.dev for a GitHub token. Check that the job has 'id-token: write'."
  exit 1
fi
token=$(jq -r '.token // empty | strings' <<< "$response" 2> /dev/null || true)
if [ -z "$token" ]; then
  error=$(jq -r '.error // empty' <<< "$response" 2> /dev/null || true)
  echo "::error::keypin.dev gave no GitHub token. ${error:-It sent an unexpected response.}"
  exit 1
fi
echo "::add-mask::$token"
gh auth login --hostname github.com --with-token --insecure-storage <<< "$token"
output reported "$(jq -r '.reported | booleans' <<< "$response" 2> /dev/null || true)"
