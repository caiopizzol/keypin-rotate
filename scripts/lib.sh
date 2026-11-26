# Shared by the action's scripts. Source it; don't run it.
# shellcheck shell=bash

KEYPIN_DEV=https://keypin.dev
WORK="$RUNNER_TEMP/keypin-rotate"
# shellcheck disable=SC2034 # used by the scripts that source this file
STAGED="$WORK/state"
export GH_CONFIG_DIR="$WORK/gh"

# Prints a GitHub OIDC token for keypin.dev. Needs `id-token: write`.
oidc_token() {
  local response
  response=$(curl -sSf --max-time 30 -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$KEYPIN_DEV") || return 1
  jq -er '.value | strings' <<< "$response"
}

# POSTs to a keypin.dev console API path with an OIDC token, and prints the response body.
# Any extra arguments go to curl.
keypin_dev_post() {
  local path=$1 oidc
  shift
  oidc=$(oidc_token) || return 1
  curl -sS --max-time 30 -X POST -H "Authorization: Bearer $oidc" "$@" "$KEYPIN_DEV/console/api/$path"
}

# Writes name=value to the step's outputs.
output() {
  echo "$1=$2" >> "$GITHUB_OUTPUT"
}
