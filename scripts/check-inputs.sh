#!/usr/bin/env bash
# Rejects inputs the later steps can't use.
set -euo pipefail

failed=0
fail() {
  echo "::error::$1"
  failed=1
}

case "$CHECK_SETUP" in
  true | false) ;;
  *) fail "check-setup must be true or false, not '$CHECK_SETUP'" ;;
esac
if ! [[ "$KEYPIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  fail "keypin-version must be an exact version, such as 0.46.1, not '$KEYPIN_VERSION'"
fi
if ! git check-ref-format "refs/heads/$STATE_BRANCH"; then
  fail "state-branch must be a branch name, not '$STATE_BRANCH'"
fi
if [ -z "$OP_SERVICE_ACCOUNT_TOKEN" ]; then
  fail "op-service-account-token is empty. Save the 1Password service account token as a secret in the job's environment."
fi
exit "$failed"
