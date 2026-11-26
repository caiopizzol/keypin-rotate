#!/usr/bin/env bash
# Copies .keypin/rotation.json and status.json out of the checkout, for the artifact and the save.
# On a first run where keypin wrote neither, there is nothing to stage.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

if [ -z "$RESTORED" ] && [ ! -e .keypin/rotation.json ] && [ ! -L .keypin/rotation.json ] &&
  [ ! -e .keypin/status.json ] && [ ! -L .keypin/status.json ]; then
  echo "::notice::keypin wrote no state, so there is nothing to save."
  output staged false
  exit 0
fi

rm -rf "$STAGED"
mkdir -p "$STAGED"
for file in rotation.json status.json; do
  if [ -L ".keypin/$file" ] || [ ! -f ".keypin/$file" ]; then
    echo "::error::.keypin/$file is missing or isn't a regular file"
    exit 1
  fi
  cp ".keypin/$file" "$STAGED/$file"
done
output staged true
