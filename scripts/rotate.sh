#!/usr/bin/env bash
# Rotates every due key, or with check-setup, only checks that rotation could run.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

if [ "$CHECK_SETUP" = true ]; then
  keypin rotate --check
  exit 0
fi

keypin rotate --due --yes
waiting=$(jq -r '.issued[] | select(.old.id != null and (.old.revoked | not)) | .key' .keypin/rotation.json 2> /dev/null) ||
  exit 0
for key in $waiting; do
  echo "::notice::The old $key still works. Approvers get an email from keypin.dev; once one approves, the next run revokes it."
done
