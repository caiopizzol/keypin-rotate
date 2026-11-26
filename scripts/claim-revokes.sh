#!/usr/bin/env bash
# Revokes the old keys approvers approved on keypin.dev, when .keypin/rotation.json still names
# the same keys. Every failure here is a warning, so rotation still runs.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

claimed=""
if ! claimed=$(keypin_dev_post revokes/claim) ||
  ! jq -e '.revokes | type == "array"' <<< "$claimed" > /dev/null 2>&1; then
  echo "::warning::Couldn't get approved revokes from keypin.dev, so this run revokes nothing. $(jq -r '.error // empty' <<< "$claimed" 2> /dev/null)"
  exit 0
fi

jq -c '.revokes[]' <<< "$claimed" | while read -r revoke; do
  key=$(jq -r '.key | strings' <<< "$revoke")
  profile=$(jq -r '.environment | strings' <<< "$revoke")
  if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$profile" =~ ^[a-z0-9-]+$ ]]; then
    echo "::warning::Skipped an approved revoke with an unexpected key or profile name."
    continue
  fi
  if ! jq -e --argjson r "$revoke" '$r.newId != null and $r.oldId != null and $r.issuedAt != null and any(.issued[]; .key == $r.key and .environment == $r.environment and .id == $r.newId and .old.id == $r.oldId and .at == $r.issuedAt and (.old.revoked | not))' .keypin/rotation.json > /dev/null 2>&1; then
    echo "::warning::Skipped $key ($profile): $STATE_BRANCH no longer matches what was approved."
    continue
  fi
  keypin rotate --approve-revoke "$key" --profile "$profile" < /dev/null ||
    echo "::warning::Revoking the old $key ($profile) failed; the next run tries again."
done
exit 0
