#!/usr/bin/env bash
# Tells keypin.dev which state commit this run saved, so it emails approvers about old keys that
# wait. A failure is a warning: the next run reports again.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

[ -n "$COMMIT" ] || exit 0
body=$(jq -nc --arg commit "$COMMIT" '{commit: $commit}')
if ! response=$(keypin_dev_post rotation-report -H "content-type: application/json" -d "$body") ||
  ! waiting=$(jq -er '.waiting | numbers' <<< "$response" 2> /dev/null); then
  echo "::warning::keypin.dev didn't record this run's state; the next run reports it again. $(jq -r '.error // empty' <<< "${response:-}" 2> /dev/null)"
  exit 0
fi
echo "Reported $COMMIT to keypin.dev. Old keys waiting for approval: $waiting."
